// Metal execution layer of the NVN null device, see nvn_mtl.h.
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CAMetalDisplayLink.h>
#import <MetalFX/MetalFX.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <dlfcn.h>
#include <TargetConditionals.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif
#include <sys/stat.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <setjmp.h>
#include "nvn_mtl.h"
// Compile-time switch DM_NVN_M3=1: the graphics backend uses the older API (ordinary command queue / command buffers / render, compute and copy encoders, buffers bound per slot, each resource referenced by an argument block declared individually),
// target macOS 15 / iOS 18. Default 0 = Metal 4 (macOS 26 / iOS 26). Both branches share the same replay logic, and every divergence is inside #if DM_NVN_M3
#ifndef DM_NVN_M3
#define DM_NVN_M3 0
#endif
#if DM_NVN_M3
#define RENC id<MTLRenderCommandEncoder>
#define CENC id<MTLComputeCommandEncoder>
#define BENC id<MTLBlitCommandEncoder>
#define CBUF id<MTLCommandBuffer>
#define RPD MTLRenderPassDescriptor
#define FB_ON(o, cb) cb
#define M4_ONLY(...)
#define M3_PRESENT(cb, dr) [cb presentDrawable:dr]
#define FB_SEL addCompletedHandler
#define FB_ARG id<MTLCommandBuffer>
#else
#define RENC id<MTL4RenderCommandEncoder>
#define CENC id<MTL4ComputeCommandEncoder>
#define BENC id<MTL4ComputeCommandEncoder>
#define CBUF id<MTL4CommandBuffer>
#define RPD MTL4RenderPassDescriptor
#define FB_ON(o, cb) o
#define M4_ONLY(...) __VA_ARGS__
#define M3_PRESENT(cb, dr) [dr present]
#define FB_SEL addFeedbackHandler
#define FB_ARG id<MTL4CommitFeedback>
#endif
#include "nvn_obj.h"
#include "../tex/nvn_fmt_mtl.h"
#include "../tex/nvn_deswizzle.h"
#include "../tex/nvn_deswizzle_gpu.h"
#include "../tex/nvn_bcdec.h"
#include "nvn_dirty.h"
#include "nvn_refl.h"
#include "nvn_cover.h"
#include "nvn_copy_pitch.h"
#include "nvn_pool_find.h"
#include "nvn_tex_fit.h"
#include "nvn_depth_clear.h"
#include "dmsh_chain.h"   // DMSH_CHAIN: the translation chain version of the B shader library expected by this source tree
#include "nvn_hmap.h"
#include "../../host/dm.h"
#import <CommonCrypto/CommonDigest.h>
#include <stdarg.h>
#include <mach-o/dyld.h>
#include <libgen.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <stdatomic.h>
#include <errno.h>
#include <execinfo.h>
#include <os/lock.h>
// Function parameters in this file are never retained again in the callee (the caller / global tables already hold them, and lifetime is guaranteed by defer_obj_release): saves a retain / release pair per call on the hot path
#pragma clang attribute push(__attribute__((objc_externally_retained)), apply_to = function)

#define MLOG(...) do { fprintf(stderr, "[dm] [nvn-mtl] " __VA_ARGS__); fputc('\n', stderr); } while (0)
#define MDIE(...) do { MLOG("FATAL " __VA_ARGS__); abort(); } while (0)

static void warm_start(void);
static void warm_claim(void);

static id<MTLDevice> g_dev;
static int g_nvn_deswz_gpu;
static id<MTLCommandQueue> g_q;
#if !DM_NVN_M3
static id<MTL4CommandQueue> g_q4;
static dispatch_queue_t g_feedback_q;
#endif
// Only one command stream queue: the game's command buffers and the presents all go to it (Metal 4: g_q4; older API: g_q; in Metal 4 builds g_q only
// serves CPU-synchronous readback / screenshots / teardown). WaitSync and WaitEvent being correct as no-ops rests on this (g_nops in hle_nvn.c):
// every command stream queue is created through here, and a second one aborts
static void stream_queue_once(void) { static int n; if (++n > 1) MDIE("[red] command stream queue #%d created: the no-op WaitSync / WaitEvent rely on a single queue (g_nops in hle_nvn.c); make them real waits before adding a queue", n); }
static _Atomic uint32_t g_present_qos;
#define ALLOC_MAX 8
static int g_alloc_n, g_alloc_cur;   // in-flight slots of the main submission (Metal 4: one command allocator per slot; older API: used only to limit the number of in-flight submissions)
#if !DM_NVN_M3
static id<MTL4CommandAllocator> g_alloc4[ALLOC_MAX];   // Command allocator pool of the main submission: at start pick one the GPU has finished with, create a new one if there is none (wait only at the cap)
static id<MTL4CommandAllocator> g_up_alloc4[3];
static id<MTL4CommandAllocator> g_present_alloc4[3];
static CBUF g_present_cb[3];
static id<MTL4ArgumentTable> g_vt, g_ft, g_ct, g_up_ct;
static id<MTL4ArgumentTable> g_present_args;
#endif
static id<MTLBuffer> g_present_uv[3];
static uint64_t g_present_alloc_fence[3];
static pthread_mutex_t g_pq_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_pq_cv = PTHREAD_COND_INITIALIZER;
static pthread_cond_t g_link_cv = PTHREAD_COND_INITIALIZER;
static pthread_mutex_t g_link_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_link_tick_ns, g_link_tick_n;
static uint64_t g_link_dropped;
static int g_pq_inflight;   // Under g_pq_mu: number of presents committed to the GPU whose completion callback has not arrived yet
int g_dm_present_link;   // Present pacing mode (runtime value of DM_PRESENT_LINK, modified directly during same-process alternating measurement): 0 = acquire the drawable itself; 1 = display link at 60 Hz; 2 = display link at 120 Hz, the game presents a frame every other display-link tick
static int g_present_latency = 1;
static uint64_t g_pq_done;
static uint64_t g_pq_read;
#if DM_NVN_M3
static id g_res;   // the MTLResidencySet (iOS 18 / macOS 15); nil on iOS 17, where the Metal 3 path's useResource declarations alone make resources resident
#else
static id<MTLResidencySet> g_res;
#endif
static int g_res_dirty;
static id<MTLSharedEvent> g_ev;
static uint64_t g_fence;                        // Highest committed fence value (incremented exclusively by the submit thread)
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static uint64_t g_done;                         // Highest completed fence value (written by the completion callback)
static _Atomic int g_last_commit_error;
static _Atomic int g_up_pending;
// Waiting for upload batches: the completion handler broadcasts after it clears a counter, the waiter blocks until it reads zero (nxnative e06a8ec's
// up_wait_zero, MIT). These waits polled with usleep(200 / 1000): each one ended up to a millisecond after the batch completed (a loader that waits
// per resource pays it per resource). The timed wait only guards against a missed completion
static pthread_mutex_t g_up_mu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t g_up_cv = PTHREAD_COND_INITIALIZER;
static void up_notify(void) { pthread_mutex_lock(&g_up_mu); pthread_cond_broadcast(&g_up_cv); pthread_mutex_unlock(&g_up_mu); }
static void up_wait_zero(_Atomic int *v) {
    pthread_mutex_lock(&g_up_mu);
    while (atomic_load(v)) { struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_nsec += 50000000; if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; } pthread_cond_timedwait(&g_up_cv, &g_up_mu, &ts); }
    pthread_mutex_unlock(&g_up_mu);
}

static pthread_mutex_t g_res_mu = PTHREAD_MUTEX_INITIALIZER;   // Dedicated lock for the residency set: res_add is called on paths that hold g_mu (arena_new), so it cannot share g_mu
static NSHashTable *g_res_objects;
#if DM_NVN_M3
// The older API binds by "buffer object + offset", while the replay layer holds GPU addresses: registered buffers (zero-copy buffers of memory pools, argument blocks, staging blocks and so on, a few dozen) are looked up by address range.
// Registered by weak reference (__unsafe_unretained, removed when residency is withdrawn); the most recently hit entry is tried first - bindings within one pass almost always land on the same one or two buffers
enum { M3_BUFS = 512 };
static struct { uint64_t gpu, len; __unsafe_unretained id<MTLBuffer> buf; } g_m3_bufs[M3_BUFS]; static int g_m3_nbufs; static os_unfair_lock g_m3_lk = OS_UNFAIR_LOCK_INIT;
static void m3_buf_add(id<MTLBuffer> b) { os_unfair_lock_lock(&g_m3_lk); if (g_m3_nbufs < M3_BUFS) { g_m3_bufs[g_m3_nbufs].gpu = b.gpuAddress; g_m3_bufs[g_m3_nbufs].len = b.length; g_m3_bufs[g_m3_nbufs++].buf = b; } os_unfair_lock_unlock(&g_m3_lk); }
static void m3_buf_del(id b) { os_unfair_lock_lock(&g_m3_lk); for (int i = 0; i < g_m3_nbufs; i++) if (g_m3_bufs[i].buf == b) { g_m3_bufs[i] = g_m3_bufs[--g_m3_nbufs]; break; } os_unfair_lock_unlock(&g_m3_lk); }
static id<MTLBuffer> m3_buf(uint64_t gpu, NSUInteger *off) {
    static _Thread_local int last; id<MTLBuffer> r = nil; *off = 0; if (!gpu) return nil;
    os_unfair_lock_lock(&g_m3_lk);
    int i = last < g_m3_nbufs && gpu >= g_m3_bufs[last].gpu && gpu - g_m3_bufs[last].gpu < g_m3_bufs[last].len ? last : -1;
    for (int k = 0; i < 0 && k < g_m3_nbufs; k++) if (gpu >= g_m3_bufs[k].gpu && gpu - g_m3_bufs[k].gpu < g_m3_bufs[k].len) i = k;
    if (i >= 0) { last = i; r = g_m3_bufs[i].buf; *off = (NSUInteger)(gpu - g_m3_bufs[i].gpu); }
    os_unfair_lock_unlock(&g_m3_lk);
    return r;
}
#endif
// Test switch DM_RES_CENSUS=1 (not normally on): records every object that has entered the residency set (weak references); on the tick of the memory readout line it reports the count and size of those "still in the residency set" and those "removed from the residency set but not yet destroyed".
// The latter = GPU memory we no longer use but someone still holds a reference to (for example a texture ID's cached view, or an autorelease pool on a guest thread that is never drained);
// the first three such textures are named, for `leaks --traceTree=<address>`
static NSHashTable *g_res_ever; static int g_res_census = -1;
static uint64_t g_res_noop;   // res_add / res_remove calls that changed nothing (the set already held / did not hold it): no addAllocation, no commit
static void res_add(id<MTLResource> r) {
    if (!r) return;
    pthread_mutex_lock(&g_res_mu);
    if ([g_res_objects containsObject:r]) { g_res_noop++; pthread_mutex_unlock(&g_res_mu); return; }   // a re-upload adds its texture again (nxnative e06a8ec)
    [g_res addAllocation:(id<MTLAllocation>)r];
    if (!g_res_objects) g_res_objects = [NSHashTable weakObjectsHashTable];
    [g_res_objects addObject:r];
#if DM_NVN_M3
    if ([r conformsToProtocol:@protocol(MTLBuffer)]) m3_buf_add((id<MTLBuffer>)r);
#endif
    if (g_res_census < 0) g_res_census = getenv("DM_RES_CENSUS") != NULL;
    if (g_res_census > 0) { if (!g_res_ever) g_res_ever = [NSHashTable weakObjectsHashTable]; [g_res_ever addObject:r]; }
    g_res_dirty = 1;
    pthread_mutex_unlock(&g_res_mu);
}
static void res_remove(id<MTLResource> r) {
    if (!r) return;
    pthread_mutex_lock(&g_res_mu);
    if (![g_res_objects containsObject:r]) { g_res_noop++; pthread_mutex_unlock(&g_res_mu); return; }
    [g_res removeAllocation:(id<MTLAllocation>)r];
    [g_res_objects removeObject:r];
#if DM_NVN_M3
    m3_buf_del(r);
#endif
    g_res_dirty = 1;
    pthread_mutex_unlock(&g_res_mu);
}
// DM_RES_CHECK=1 (diagnostic): if textures / buffers the shader accesses through the argument block are not in the residency set, print the first 40 (textures are attributed to the actual allocation via parent texture / underlying buffer)
static int g_res_check_on;
static void res_check(id r, const char *what, int reg) {
    static int nbad;
    if (!g_res_check_on || !r || nbad >= 40) return;
    int is_tex = [r conformsToProtocol:@protocol(MTLTexture)], is_buf = [r conformsToProtocol:@protocol(MTLBuffer)];
    if (!is_tex && !is_buf) return;   // Samplers etc. are not allocations
    id<MTLResource> a = r; int hops = 0;
    if (is_tex) { id<MTLTexture> t = (id<MTLTexture>)a; while (t.parentTexture) { t = t.parentTexture; hops++; } a = t.buffer ? (id<MTLResource>)t.buffer : (id<MTLResource>)t; }
    pthread_mutex_lock(&g_res_mu); int ok = [g_res_objects containsObject:a]; pthread_mutex_unlock(&g_res_mu);
    if (!ok) { nbad++; id<MTLTexture> t = is_tex ? (id<MTLTexture>)r : nil;
        MLOG("[red] residency missing #%d: %s slot %d %s %p (parent chain %d levels) allocated %lu B storage %lu%s", nbad, what, reg, is_tex ? "texture" : "buffer", (__bridge void *)a, hops, (unsigned long)a.allocatedSize, (unsigned long)a.storageMode,
             t ? [NSString stringWithFormat:@" format %lu %lux%lu type %lu usage %#lx", (unsigned long)t.pixelFormat, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.textureType, (unsigned long)t.usage].UTF8String : ""); }
}
static void res_commit(void) {
    pthread_mutex_lock(&g_res_mu);
    if (g_res_dirty) { [g_res commit]; g_res_dirty = 0; }
    pthread_mutex_unlock(&g_res_mu);
}

@interface NvDeferredRelease : NSObject { @public id object; uint64_t fence; int keep_resident; } @end
@implementation NvDeferredRelease @end
static NSMutableArray<NvDeferredRelease *> *g_deferred;
static pthread_mutex_t g_deferred_mu = PTHREAD_MUTEX_INITIALIZER;
// Deferred release has two meanings that must be kept apart (the root of the GPU memory fault on the first frame on entering Travincal):
//   defer_obj_release = this object is retired: drop the reference after the submissions that used it complete, and remove it from the residency set;
//   defer_obj_unref   = only the reference I hold is no longer wanted, the object itself may still be in use (the view cache of a texture ID may hold the base texture itself): only drop the reference, leave the residency set alone.
// Previously only the former existed: when the view cache was invalidated, a texture that 'is still the current storage of some serial' was also removed from the residency set. Invalidation used to happen only when the base texture was really replaced, so it was never hit;
// after the transparency chain's in-place composite swapped the storage of two textures, each of the two live textures was removed once this way, and afterwards they are used as attachments and sampled every frame as usual - the GPU accesses non-resident memory.
static void defer_obj_release_ex(id obj, int keep_resident) {
    if (!obj) return;
    NvDeferredRelease *d = [NvDeferredRelease new]; d->object = obj; d->fence = g_fence + 1; d->keep_resident = keep_resident;
    pthread_mutex_lock(&g_deferred_mu);
    if (!g_deferred) g_deferred = [NSMutableArray array];
    [g_deferred addObject:d];
    pthread_mutex_unlock(&g_deferred_mu);
}
static void defer_obj_release(id obj) { defer_obj_release_ex(obj, 0); }
static void defer_obj_unref(id obj) { defer_obj_release_ex(obj, 1); }
static void defer_drain(void) {
    NSMutableArray<NvDeferredRelease *> *ready = [NSMutableArray array];
    pthread_mutex_lock(&g_deferred_mu);
    for (NSInteger i = g_deferred.count - 1; i >= 0; i--) {
        NvDeferredRelease *d = g_deferred[(NSUInteger)i];
        if (d->fence <= g_done) { [ready addObject:d]; [g_deferred removeObjectAtIndex:(NSUInteger)i]; }
    }
    pthread_mutex_unlock(&g_deferred_mu);
    for (NvDeferredRelease *d in ready) {
        id obj = d->object;
        if (!d->keep_resident && [obj conformsToProtocol:@protocol(MTLResource)]) {
            pthread_mutex_lock(&g_res_mu);
            int registered = [g_res_objects containsObject:obj];
            pthread_mutex_unlock(&g_res_mu);
            if (registered) res_remove((id<MTLResource>)obj);
        }
        d->object = nil;
    }
}

static pthread_mutex_t g_bf_want_mu = PTHREAD_MUTEX_INITIALIZER;
static char **g_bf_want_keys; static size_t g_bf_want_n, g_bf_want_cap; static int g_bf_want_loaded;
// DM_NVN_BF_WANT=<file>: append the key of each fragment shader that would need an output-mapping-only readable-tile variant (dmsh_build.py
// DMSH_BF_WANT reads the same list). Shader keys here carry the library suffix ("<16 hex>_b"); the list holds the bare 16-digit key.
void bf_want_note(const char *shader_key) {
    const char *path = getenv("DM_NVN_BF_WANT");
    if (!path || !shader_key || strlen(shader_key) < 16 || (shader_key[16] && shader_key[16] != '_')) return;
    for (int i = 0; i < 16; i++) if (!((shader_key[i] >= '0' && shader_key[i] <= '9') || (shader_key[i] >= 'a' && shader_key[i] <= 'f') || (shader_key[i] >= 'A' && shader_key[i] <= 'F'))) return;
    char key[17]; memcpy(key, shader_key, 16); key[16] = 0;
    pthread_mutex_lock(&g_bf_want_mu);
    if (!g_bf_want_loaded) {
        FILE *f = fopen(path, "r"); char line[64];
        if (f) { while (fgets(line, sizeof line, f)) { char *e = strpbrk(line, "\r\n"); if (e) *e = 0; if (strlen(line) != 16) continue;
                if (g_bf_want_n == g_bf_want_cap) { g_bf_want_cap = g_bf_want_cap ? g_bf_want_cap * 2 : 64; g_bf_want_keys = realloc(g_bf_want_keys, g_bf_want_cap * sizeof *g_bf_want_keys); }
                g_bf_want_keys[g_bf_want_n++] = strdup(line); } fclose(f); }
        g_bf_want_loaded = 1;
    }
    for (size_t i = 0; i < g_bf_want_n; i++) if (!strcmp(g_bf_want_keys[i], key)) { pthread_mutex_unlock(&g_bf_want_mu); return; }
    if (g_bf_want_n == g_bf_want_cap) { g_bf_want_cap = g_bf_want_cap ? g_bf_want_cap * 2 : 64; g_bf_want_keys = realloc(g_bf_want_keys, g_bf_want_cap * sizeof *g_bf_want_keys); }
    g_bf_want_keys[g_bf_want_n++] = strdup(key);
    FILE *f = fopen(path, "a"); if (f) { fprintf(f, "%s\n", key); fclose(f); }
    pthread_mutex_unlock(&g_bf_want_mu);
}

// ---------- Memory pools ----------
typedef struct { uintptr_t lo, hi; uintptr_t base; __unsafe_unretained id<MTLBuffer> buf; uint64_t gpu; const void *key; int res; } pool_ent;   // res: already put in the residency set (on demand, see pool_res)
static pool_ent *g_pools; static int g_npool, g_cap;
_Static_assert(offsetof(pool_ent, lo) == 0 && offsetof(pool_ent, hi) == sizeof(uintptr_t), "nvn_pool_find.h reads lo, hi at the start of an entry");
static pool_find_t g_pfind = {.last = -1};   // address → pool (nvn_pool_find.h); reset whenever g_pools changes, under g_mu
static NSMutableArray *g_keep;                  // Holds the buffer references (pool_ent has non-owning pointers)
static uint64_t g_pool_adds;

#define C1_BANK_SIZE (4u << 20)
#define C1_DECL_SIZE (64u << 10)
static NSMutableArray *g_c1_banks;
static size_t g_c1_bank_off, g_c1_alloc_bytes, g_c1_data_bytes;
static uint64_t g_c1_count, g_c1_exclusive;
static NSMutableSet<NSString *> *g_c1_full;
static int g_c1_full_valid;
static os_unfair_lock g_c1_lock = OS_UNFAIR_LOCK_INIT;

// DM_UDC_SELFTEST=1 (diagnostic, checks DontCare behavior on a real A19 device): private-storage Depth32Float_Stencil8 / RGBA8 (1952x900) are first cleared to write known values,
// then Load + DontCare without drawing, read back and compared pixel by pixel, printing one result line
static void udc_selftest(void) {
    if (!getenv("DM_UDC_SELFTEST")) return;
    id<MTLCommandQueue> q = [g_dev newCommandQueue];
    for (int depth = 1; depth >= 0; depth--) {
        NSUInteger w = 1952, h = 900;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:depth ? MTLPixelFormatDepth32Float_Stencil8 : MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> t = [g_dev newTextureWithDescriptor:td];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        for (int pass = 0; pass < 2; pass++) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            MTLLoadAction la = pass ? MTLLoadActionLoad : MTLLoadActionClear; MTLStoreAction sa = pass ? MTLStoreActionDontCare : MTLStoreActionStore;
            if (depth) { rp.depthAttachment.texture = t; rp.depthAttachment.loadAction = la; rp.depthAttachment.storeAction = sa; rp.depthAttachment.clearDepth = 0.3125;
                         rp.stencilAttachment.texture = t; rp.stencilAttachment.loadAction = la; rp.stencilAttachment.storeAction = sa; rp.stencilAttachment.clearStencil = 0x5a; }
            else { rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = la; rp.colorAttachments[0].storeAction = sa; rp.colorAttachments[0].clearColor = MTLClearColorMake(0.2, 0.4, 0.6, 0.8); }
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        }
        id<MTLBuffer> out = [g_dev newBufferWithLength:w * h * 4 options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:out destinationOffset:0
            destinationBytesPerRow:w * 4 destinationBytesPerImage:w * h * 4 options:depth ? MTLBlitOptionDepthFromDepthStencil : MTLBlitOptionNone];
        [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const uint32_t *px = out.contents; NSUInteger bad = 0; for (NSUInteger i = 0; i < w * h; i++) if (px[i] != px[0]) bad++;
        MLOG("UDC self-test %s %s %lux%lu first value %08x, differing from first value %lu / %lu", g_dev.name.UTF8String, depth ? "Depth32F_S8" : "RGBA8", (unsigned long)w, (unsigned long)h, px[0], (unsigned long)bad, (unsigned long)(w * h));
    }
}
// Entry points the game's threads reach outside a submission run inside their own autorelease pool (@autoreleasepool at the top of each): guest
// threads have no pool, and an autorelease with none creates a thread-level pool that is never drained (seen holding retired textures autoreleased
// in mtl_init and WriteTexels; OBJC_DEBUG_MISSING_POOLS=YES lists what is still missed). Submissions push their own pool (mtl_sub_begin)
void mtl_init(void) { @autoreleasepool {
    if (g_dev) return;
    const char *link = getenv("DM_PRESENT_LINK");
    g_dm_present_link = link ? atoi(link) : 1; if (g_dm_present_link < 0 || g_dm_present_link > 2) g_dm_present_link = 1;   // Default 1 (real-device same-process alternation: when load exceeds one display-link period, long frames 15% → 0 and frame intervals even out; no difference from 0 at a steady 60); DM_PRESENT_LINK=0 turns it off   // 1 = present on every tick of a 60 Hz display link; 2 = 120 Hz display link, the game presents a frame every other display-link tick (when behind, it can present on the next 8.33 ms display-link tick)
    const char *latency = getenv("DM_PRESENT_LATENCY");
    if (latency && atoi(latency) > 0) g_present_latency = atoi(latency);
    g_res_check_on = getenv("DM_RES_CHECK") != NULL;
    g_dev = MTLCreateSystemDefaultDevice();
    if (!g_dev) MDIE("no Metal device");
    if (!g_dev.hasUnifiedMemory) MDIE("a unified-memory device is required (zero-copy memory pools)");
    g_q = [g_dev newCommandQueue];
#if DM_NVN_M3
    stream_queue_once();
#endif
    NSError *re = nil;
    if (@available(iOS 18.0, macOS 15.0, *)) {   // (4ppp44's iOS 17 build compiles the set out; checked here, one Metal 3 binary keeps it from iOS 18 on)
        MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new];
        rd.initialCapacity = 4096;
        g_res = [g_dev newResidencySetWithDescriptor:rd error:&re];
        if (!g_res) MDIE("failed to create MTLResidencySet");
        [g_q addResidencySet:g_res];
    } else MLOG("no residency set before iOS 18: resources are made resident by the encoders' useResource declarations only");
    { void crash_set_wait_dump(void (*fn)(void)); void mtl_wait_state_dump(void); crash_set_wait_dump(mtl_wait_state_dump); }
#if !DM_NVN_M3
    dispatch_queue_attr_t feedback_attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    g_feedback_q = dispatch_queue_create("dm.nvn.mtl4-feedback", feedback_attr);
    MTL4CommandQueueDescriptor *q4d = [MTL4CommandQueueDescriptor new]; q4d.feedbackQueue = g_feedback_q;
    g_q4 = [g_dev newMTL4CommandQueueWithDescriptor:q4d error:&re];
    if (!g_q4) MDIE("failed to create MTL4CommandQueue");
    stream_queue_once();
    [g_q4 addResidencySet:g_res];
#endif
    g_alloc_n = 3;
#if !DM_NVN_M3
    for (int i = 0; i < 3; i++) {
        MTL4CommandAllocatorDescriptor *ad = [MTL4CommandAllocatorDescriptor new];
        ad.label = [NSString stringWithFormat:@"nvn-mtl allocator %d", i];
        NSError *ae = nil;
        g_alloc4[i] = [g_dev newCommandAllocatorWithDescriptor:ad error:&ae];
        if (!g_alloc4[i]) MDIE("failed to create MTL4CommandAllocator[%d]: %s", i, ae.localizedDescription.UTF8String);
        g_up_alloc4[i] = [g_dev newCommandAllocatorWithDescriptor:ad error:&ae];
        if (!g_up_alloc4[i]) MDIE("failed to create upload MTL4CommandAllocator[%d]: %s", i, ae.localizedDescription.UTF8String);
        MTL4CommandAllocatorDescriptor *pad = [MTL4CommandAllocatorDescriptor new];
        pad.label = [NSString stringWithFormat:@"nvn-mtl present allocator %d", i];
        g_present_alloc4[i] = [g_dev newCommandAllocatorWithDescriptor:pad error:&ae];
        if (!g_present_alloc4[i]) MDIE("failed to create present MTL4CommandAllocator[%d]: %s", i, ae.localizedDescription.UTF8String);
        g_present_cb[i] = [g_dev newCommandBuffer];
        if (!g_present_cb[i]) MDIE("failed to create present MTL4CommandBuffer[%d]", i);
    }
    MTL4ArgumentTableDescriptor *atd = [MTL4ArgumentTableDescriptor new];
    atd.maxBufferBindCount = 31; atd.maxTextureBindCount = 1;
    NSError *ate = nil;
    g_vt = [g_dev newArgumentTableWithDescriptor:atd error:&ate]; if (!g_vt) MDIE("failed to create vertex argument table: %s", ate.localizedDescription.UTF8String);
    g_ft = [g_dev newArgumentTableWithDescriptor:atd error:&ate]; if (!g_ft) MDIE("failed to create fragment argument table: %s", ate.localizedDescription.UTF8String);
    g_ct = [g_dev newArgumentTableWithDescriptor:atd error:&ate]; if (!g_ct) MDIE("failed to create compute argument table: %s", ate.localizedDescription.UTF8String);
    g_up_ct = [g_dev newArgumentTableWithDescriptor:atd error:&ate]; if (!g_up_ct) MDIE("failed to create upload compute argument table: %s", ate.localizedDescription.UTF8String);
    MTL4ArgumentTableDescriptor *pad = [MTL4ArgumentTableDescriptor new];
    pad.maxTextureBindCount = 1; pad.maxSamplerStateBindCount = 1; pad.maxBufferBindCount = 1;
    g_present_args = [g_dev newArgumentTableWithDescriptor:pad error:&ate];
    if (!g_present_args) MDIE("failed to create present argument table: %s", ate.localizedDescription.UTF8String);
#endif
    for (int i = 0; i < 3; i++) {
        g_present_uv[i] = [g_dev newBufferWithLength:sizeof(float) * 8 options:MTLResourceStorageModeShared];
        if (!g_present_uv[i]) MDIE("failed to create present UV buffer[%d]", i);
        res_add(g_present_uv[i]);
    }
    g_ev = [g_dev newSharedEvent];
    g_keep = [NSMutableArray array];
    g_nvn_deswz_gpu = nvn_deswz_gpu_init(g_dev) == 0;
    if (!g_nvn_deswz_gpu) MLOG("[red] GPU deswizzle init failed, swizzled textures fall back to the CPU");
    MLOG("Metal device %s", g_dev.name.UTF8String);
    udc_selftest();
} }

static _Atomic uint64_t g_reg_gen = 1;   // Change generation of memory pool / texture / sampler registration: one of the invalidation conditions for argument buffer reuse
// On-demand residency of memory pools: putting a zero-copy buffer into the residency set makes iOS read the whole pool into memory and pin it as wired (not counted in footprint and never paged out), even a pool the game never uses -
// measured on a 17 Pro Max: the 512 MB render-target pool is addressed 0 times in a run, and putting it into the residency set raises device wired memory by about 530 MB; this is why an A14 4 GB device was ended by the system for running out of memory within seconds of launch (public repository #37).
// So a pool is not put into the residency set when created; it is put in, and the residency set committed on the spot, the first time the GPU gets its address through mtl_addr / mtl_gpu_addr
// (these are the only two ways the GPU gets pool addresses; committing on the spot = earlier than any command buffer commit that uses it, without relying on each commit point calling res_commit). Caller holds g_mu
static uint64_t g_cb_commits, g_pool_res_at;   // number of command buffers committed (main + upload); this number at the last on-demand residency (0 = nothing pending to check)
static void pool_res(int i) {
    if (g_pools[i].res) return;
    res_add(g_pools[i].buf); res_commit(); g_pools[i].res = 1; g_pool_res_at = g_cb_commits + 1;
    MLOG("on-demand memory pool residency: a %llu MB pool had its address taken for the first time, added to the residency set and committed (command buffers committed so far: %llu)",
         (unsigned long long)((g_pools[i].hi - g_pools[i].lo) >> 20), (unsigned long long)g_cb_commits);
}
static void cb_committed(void) {   // called after the main submission / upload submission: checks that "the residency set commit is earlier than the first command buffer commit that uses it", one line after each on-demand residency
    pthread_mutex_lock(&g_mu); uint64_t n = ++g_cb_commits, at = g_pool_res_at; if (at) g_pool_res_at = 0; pthread_mutex_unlock(&g_mu);
    if (at) MLOG("on-demand memory pool residency: the first command buffer committed after that is #%llu (residency set committed before #%llu)", (unsigned long long)n, (unsigned long long)at);
}
// A memory pool's zero-copy buffer makes its whole range resident (on iOS wired). Ranges with unmapped holes, pages that are not readable, or read-only
// pages the dirty tracker did not protect (its read-only pages are mapped and really read-write), and ranges above POOL_BUFFER_MAX are refused with a
// red line instead of being handed to the driver: twice MacNativeGames saw macOS kernel panics in IOGPUFamily right after kIOReturnNoMemory
// (pool_range_check, ly05010419/MacNativeGames, MIT; written anew here, refusing the pool instead of stopping). A refused pool has no buffer: its
// textures still work (separate Metal textures), buffer accesses into it report as outside every pool
#define POOL_BUFFER_MAX (1ull << 30)
static uint64_t g_pool_refused, g_pool_max;
static int pool_range_ok(uintptr_t a, uintptr_t b, const void *mem, uint64_t size) {
    if (b - a > g_pool_max) g_pool_max = b - a;
    if (b - a > POOL_BUFFER_MAX) { MLOG("[red] memory pool %p+%#llx: a %llu MiB zero-copy GPU buffer refused (limit %llu MiB)", mem, (unsigned long long)size, (unsigned long long)((b - a) >> 20), POOL_BUFFER_MAX >> 20); return 0; }
    for (vm_address_t at = a; at < b;) {
        vm_address_t ra = at; vm_size_t rs = 0; vm_region_basic_info_data_64_t ri; mach_msg_type_number_t rc = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t ro = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &ra, &rs, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&ri, &rc, &ro) != KERN_SUCCESS || ra > at) {
            MLOG("[red] memory pool %p+%#llx: unmapped pages at %#llx, refused for a zero-copy GPU buffer", mem, (unsigned long long)size, (unsigned long long)at); return 0; }
        uintptr_t lo = ra < a ? a : (uintptr_t)ra, hi = ra + rs > b ? b : (uintptr_t)(ra + rs);
        if (!(ri.protection & VM_PROT_READ) || (!(ri.protection & VM_PROT_WRITE) && !nvn_dirty_tracked((const void *)lo, hi - lo))) {
            MLOG("[red] memory pool %p+%#llx: pages at %#llx+%#llx have protection %d, refused for a zero-copy GPU buffer", mem, (unsigned long long)size, (unsigned long long)lo, (unsigned long long)(hi - lo), ri.protection); return 0; }
        at = ra + rs;
    }
    return 1;
}
// Address → pool cache per thread for mtl_addr / mtl_gpu_addr (nxnative e06a8ec, MIT): 8 entries replaced in turn, valid while g_pool_gen is
// unchanged (every pool add and removal bumps it under g_mu), holding only pools already resident. Every buffer binding of every draw used to take
// g_mu, which game threads creating pools and GPU completion handlers take too, and search the pool index. A removed pool's buffer is released only
// after the submissions using it complete (defer_obj_release), so an entry read just before a removal still names a live buffer
static _Atomic uint64_t g_pool_gen = 1;
typedef struct { uintptr_t lo, hi, base; __unsafe_unretained id<MTLBuffer> buf; uint64_t gpu; } pc_ent;
static __thread struct { uint64_t gen; unsigned n, next; pc_ent e[8]; } t_pc;
static _Atomic uint64_t g_pc_hits;   // cache hits (diagnostics, t_poolcache)
static inline const pc_ent *pc_get(uint64_t addr, uint64_t len) {
    if (t_pc.gen != atomic_load_explicit(&g_pool_gen, memory_order_acquire)) return NULL;
    for (unsigned k = 0; k < t_pc.n; k++) { const pc_ent *c = &t_pc.e[k]; if (addr >= c->lo && addr + len <= c->hi) return c; }
    return NULL;
}
static void pc_put(int i) {   // caller holds g_mu; pool i is resident
    uint64_t gen = atomic_load_explicit(&g_pool_gen, memory_order_relaxed);
    if (t_pc.gen != gen) { t_pc.gen = gen; t_pc.n = 0; t_pc.next = 0; }
    pc_ent *c = &t_pc.e[t_pc.n < 8 ? t_pc.n++ : t_pc.next++ % 8];
    *c = (pc_ent){g_pools[i].lo, g_pools[i].hi, g_pools[i].base, g_pools[i].buf, g_pools[i].gpu};
}
void mtl_pool_add(const void *mem, uint64_t size) { @autoreleasepool {
    mtl_init(); g_reg_gen++;
    uintptr_t pg = (uintptr_t)getpagesize(), lo = (uintptr_t)mem, hi = lo + size;
    uintptr_t a = lo & ~(pg - 1), b = (hi + pg - 1) & ~(pg - 1);
    if (!pool_range_ok(a, b, mem, size)) { g_pool_refused++; return; }
    id<MTLBuffer> buf = [g_dev newBufferWithBytesNoCopy:(void *)a length:b - a options:MTLResourceStorageModeShared deallocator:nil];
    if (!buf) MDIE("memory pool %p+%#llx: failed to create zero-copy buffer", mem, (unsigned long long)size);
    pthread_mutex_lock(&g_mu);
    if (g_npool == g_cap) { g_cap = g_cap ? g_cap * 2 : 64; g_pools = realloc(g_pools, g_cap * sizeof *g_pools); }
    g_pools[g_npool++] = (pool_ent){lo, hi, a, buf, buf.gpuAddress, mem, 0}; pool_find_reset(&g_pfind); atomic_fetch_add(&g_pool_gen, 1);   // not in the residency set yet: put in the first time it is addressed (pool_res)
    g_pool_adds++;
    [g_keep addObject:buf];
    pthread_mutex_unlock(&g_mu);
} }

void mtl_pool_del(const void *mem) { @autoreleasepool {
    g_reg_gen++;
    id<MTLBuffer> gone = nil;
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < g_npool; i++)
        if (g_pools[i].key == mem) { gone = g_pools[i].buf; [g_keep removeObject:gone]; g_pools[i] = g_pools[--g_npool]; pool_find_reset(&g_pfind); atomic_fetch_add(&g_pool_gen, 1); break; }
    pthread_mutex_unlock(&g_mu);
    defer_obj_release(gone);   // retire: release after the submissions that used it complete, and remove from the residency set (it used to be only removed from g_keep - the residency set holds it strongly, so the zero-copy buffer object was never destroyed)
} }

int mtl_addr(uint64_t addr, uint64_t len, void **buf, uint64_t *off) {
    const pc_ent *c = pc_get(addr, len);
    if (c) { atomic_fetch_add_explicit(&g_pc_hits, 1, memory_order_relaxed); *buf = (__bridge void *)c->buf; *off = addr - c->base; return 1; }
    int ok = 0;
    pthread_mutex_lock(&g_mu);
    int i = pool_find(&g_pfind, g_pools, sizeof *g_pools, g_npool, addr, len);
    if (i >= 0) { pool_res(i); *buf = (__bridge void *)g_pools[i].buf; *off = addr - g_pools[i].base; ok = 1; pc_put(i); }
    pthread_mutex_unlock(&g_mu);
    return ok;
}
int mtl_pool_has(uint64_t addr, uint64_t len) {
    pthread_mutex_lock(&g_mu); int i = pool_find(&g_pfind, g_pools, sizeof *g_pools, g_npool, addr, len); pthread_mutex_unlock(&g_mu);
    return i >= 0;
}
int mtl_gpu_addr(uint64_t addr, uint64_t len, void **buf, uint64_t *off, uint64_t *gpu) {
    const pc_ent *c = pc_get(addr, len);
    if (c) { atomic_fetch_add_explicit(&g_pc_hits, 1, memory_order_relaxed); *buf = (__bridge void *)c->buf; *off = addr - c->base; *gpu = c->gpu + *off; return 1; }
    int ok = 0;
    pthread_mutex_lock(&g_mu);
    int i = pool_find(&g_pfind, g_pools, sizeof *g_pools, g_npool, addr, len);
    if (i >= 0) { pool_res(i); *buf = (__bridge void *)g_pools[i].buf; *off = addr - g_pools[i].base; *gpu = g_pools[i].gpu + *off; ok = 1; pc_put(i); }
    pthread_mutex_unlock(&g_mu);
    return ok;
}

// ---------- Submission ----------
static void defer_reset(void); static void defer_fallback(void);
typedef struct { int kind; volatile uint32_t *val; uint32_t mode, v; uint64_t addr; uint32_t type; void *vis; } post_op;   // vis: the visibility slot table for kind 3
// ---------- Occlusion queries (NVN_COUNTER_TYPE_SAMPLES_PASSED) ----------
// NVN semantics: samples passed is a cumulative counter on the queue - ResetCounter zeroes it, every draw afterwards adds to it, and ReportCounter writes out the cumulative value at that moment (+ timestamp) when the GPU completes.
// Metal: every render pass attaches a visibility result buffer; draws during counting use counting mode, with a new slot per pass (no reliance on accumulation across passes); a reset empties the 'slot table since the reset',
// and a report hands the slot table together with its buffer (retained) to the completion callback to sum and write back; after a report a new slot is used, so later draws are not counted into the reported value.
// (Previously always wrote 0: occlusion query = 'fully occluded', campfires / light sources got culled - the character select screen calls ResetCounter 21 times per frame)
// A count can span submissions (no reset between them): before a ring buffer is used again, the slots of the open count in it are added into
// g_vis_base, read once its submission has completed (the ring only hands out completed buffers); a report adds the base to its slots and a reset
// clears it. Without it both slot entries read the reused slot: 64 samples, then 32 in the next submission, reported 64 (lordran-native 3ef6915, MIT)
typedef struct { void *buf; uint32_t slot; } vis_slot;
typedef struct { uint64_t base; int n; vis_slot s[]; } vis_list;
#define VIS_SLOTS 8192
typedef struct { __strong id<MTLBuffer> buf; uint64_t fence; } vis_buf;
static vis_buf g_vis_ring[4]; static int g_vis_ring_n, g_vis_ring_i = -1;
static id<MTLBuffer> g_vis; static uint32_t g_vis_n;   // This submission's visibility buffer and number of slots used
static int vis_in_ring(id<MTLBuffer> b) { for (int i = 0; i < g_vis_ring_n; i++) if (g_vis_ring[i].buf == b) return 1; return 0; }
static int g_vis_on, g_vis_counting, g_vis_cur = -1; static uint64_t g_vis_cur_pass;
static vis_slot *g_vs; static int g_nvs, g_vscap;      // Slots since the last reset
static uint64_t g_vis_base;                              // Samples of slots since the last reset whose buffer was used again (see above)
static uint64_t g_vis_folded;                            // Slots added into g_vis_base (diagnostics, the unit test)
static uint64_t g_cnt_report[32], g_cnt_reset[32];       // Report / reset counts per counter type (diagnostics)
// DM_NVN_COUNTS=1 counters (see count_self_sample)
static int g_cnt_on = -1;
static uint64_t g_cnt_self, g_cnt_self_ov, g_cnt_self_dep, g_cnt_ts, g_cnt_ts_multi, g_cnt_cleartex, g_cnt_nodraw, g_cnt_pass_d0, g_cnt_bar_at, g_cnt_first_ts; static int g_cnt_sub_ts;
static uint64_t g_cnt_rp, g_cnt_rp_sub, g_cnt_rp_px, g_cnt_rp_out, g_cnt_rp_subc, g_cnt_rp_outc; static uint32_t g_cnt_ext_x, g_cnt_ext_y; static int g_cnt_ext_clr;   // item 46: the part of a pass its draws reach
__attribute__((weak)) void dm_watch_load(uint64_t addr, uint64_t len) { (void)addr; (void)len; }   // host/diag.c (Mac)
__attribute__((weak)) void svc_guest_layout(uint8_t **alias, size_t *alias_n, uint8_t **stack, size_t *stack_n, uint8_t **heap, size_t *heap_n) {   // host/hle_svc.c
    *alias = *stack = *heap = NULL; *alias_n = *stack_n = *heap_n = 0; }
static char g_cnt_why[200];   // the first overlap of the draw being counted
static int counts_on(void) { if (g_cnt_on < 0) g_cnt_on = getenv("DM_NVN_COUNTS") && strcmp(getenv("DM_NVN_COUNTS"), "0"); return g_cnt_on; }
void mtl_counts(uint64_t out[13]) { uint64_t v[13] = {g_cnt_self, g_cnt_self_ov, g_cnt_self_dep, g_cnt_ts, g_cnt_ts_multi, g_cnt_cleartex, g_cnt_nodraw, g_cnt_rp, g_cnt_rp_sub, g_cnt_rp_px, g_cnt_rp_out, g_cnt_rp_subc, g_cnt_rp_outc}; memcpy(out, v, sizeof v); }
static inline void cnt_extent(MTLScissorRect sc, double vx0, double vy0, double vx1, double vy1) {   // the right and bottom edges a draw can reach (scissor and viewport)
#ifdef DM_TEST_EXTENT_BROKEN   // negative control of t_extent only: the viewport left out
    vx0 = vx1 = (double)(sc.x + sc.width); vy0 = vy1 = (double)(sc.y + sc.height);
#endif
    double x1 = MIN((double)(sc.x + sc.width), MAX(vx0, vx1)), y1 = MIN((double)(sc.y + sc.height), MAX(vy0, vy1));
    if (x1 > g_cnt_ext_x) g_cnt_ext_x = (uint32_t)ceil(x1); if (y1 > g_cnt_ext_y) g_cnt_ext_y = (uint32_t)ceil(y1);
}
static void vis_clear(void) { for (int i = 0; i < g_nvs; i++) CFRelease(g_vs[i].buf); g_nvs = 0; g_vis_cur = -1; g_vis_base = 0; }
#ifndef DM_TEST_VIS_NO_FOLD   // negative control of t_visibility only: the slots stay listed and read the reused buffer
static void vis_recycle(id<MTLBuffer> b) {   // b's last submission has completed and b is about to be used again
    int keep = 0, n = 0;
    for (int i = 0; i < g_nvs; i++) {
        if (g_vs[i].buf == (__bridge void *)b) { g_vis_base += ((const uint64_t *)b.contents)[g_vs[i].slot]; CFRelease(g_vs[i].buf); n++; }
        else g_vs[keep++] = g_vs[i];
    }
    g_nvs = keep; g_vis_folded += (uint64_t)n;
    if (n) { static int once; if (!once++) MLOG("occlusion count across submissions: %d slots of a reused visibility buffer kept as %llu samples (logged once)", n, (unsigned long long)g_vis_base); }
}
#else
static void vis_recycle(id<MTLBuffer> b) { (void)b; }
#endif
static vis_list *vis_snapshot(void) {
    vis_list *l = malloc(sizeof *l + g_nvs * sizeof(vis_slot)); l->base = g_vis_base; l->n = g_nvs;
    for (int i = 0; i < g_nvs; i++) { l->s[i] = g_vs[i]; CFRetain(g_vs[i].buf); }
    return l;
}
// Target ranges of buffer writes (copies / inline uniform updates) encoded but not yet executed on the GPU, in this submission and in earlier ones
// still running: reading these addresses on the CPU side at encode time yields old values. Entries stay until their submission completes (pend_begin):
// the acquire sync no longer holds the CPU until the previous frame has run, and Tears of the Kingdom updates ring-buffer uniform blocks inline one
// submission before the draws that read storage buffer pointers out of them (MacNativeGames' pend_begin, 16384 entries; MIT)
// g_pend_data: an inline update's bytes (its copy in the update ring, alive until its submission completes); NULL for a GPU copy, whose source is
// g_pend_src (0: not known); g_pend_fence: the fence of the entry's submission; g_pend_over_fence: a submission whose writes did not fit
#define PEND_MAX 16384
static uint64_t g_pend_lo[PEND_MAX], g_pend_hi[PEND_MAX], g_pend_src[PEND_MAX], g_pend_fence[PEND_MAX], g_pend_over_fence; static const uint8_t *g_pend_data[PEND_MAX]; static int g_npend, g_pend_over;
static int pend_hits(uint64_t a, uint64_t n) { if (g_pend_over) return 1; for (int i = 0; i < g_npend; i++) if (a < g_pend_hi[i] && a + n > g_pend_lo[i]) return 1; return 0; }
static void pend_note(uint64_t dst, uint64_t n, const uint8_t *data, uint64_t src) {
    if (g_npend < PEND_MAX) { g_pend_lo[g_npend] = dst; g_pend_hi[g_npend] = dst + n; g_pend_data[g_npend] = data; g_pend_src[g_npend] = src; g_pend_fence[g_npend] = g_fence + 1; g_npend++; }
    else { g_pend_over = 1; g_pend_over_fence = g_fence + 1; }
}
static void pend_begin(uint64_t done) {   // submission start: the writes of submissions that have completed are in memory now
    int n = 0;
    for (int i = 0; i < g_npend; i++) if (g_pend_fence[i] > done) {
        g_pend_lo[n] = g_pend_lo[i]; g_pend_hi[n] = g_pend_hi[i]; g_pend_data[n] = g_pend_data[i]; g_pend_src[n] = g_pend_src[i]; g_pend_fence[n] = g_pend_fence[i]; n++; }
    g_npend = n; g_pend_over = g_pend_over_fence > done;
}
// ---------- Uniform snapshots (method from MacNativeGames' usnap, ly05010419/MacNativeGames nvn_mtl.m, MIT; written anew here) ----------
// A submission is replayed inside nvnQueueSubmitCommands for 10-17 ms and its GPU work starts after that; on the console the call returns at once
// and the GPU reads the constants soon after. Tears of the Kingdom, having handed the frame over, rebuilds per-object constant pools on other threads
// (MacNativeGames found main+0x87a604, called from main+0x874f50): in the dive from the Great Sky Island up to 1041 bound uniform ranges of one
// submission changed while it was on the GPU (DM_NVN_GPUWATCH, byte compare; vertex stage slot 4, 256 bytes: the objects' transforms), and those
// frames showed rock walls in front of the camera, a flat ground or no terrain. So when a submission starts, every uniform range it binds is copied
// into its argument arena (ranges up to 256 bytes apart in one memory pool merged, at most 1 MiB each, each copy at the same offset modulo 256), and
// bindings and replay-time reads use the copy. A GPU write within the submission that reaches a copied range (inline update, buffer copy, texture to
// buffer copy, a writable storage buffer) drops that copy from then on: later readers see memory, where the GPU applies the writes in order. A range
// that a GPU write of an earlier, still running submission reaches is not copied (its result is not in memory yet). DM_NVN_UBO_SNAPSHOT=0 reads live
// memory.
typedef struct { uint64_t lo, hi; uint8_t *cpu; uint64_t gpu; void *buf; int dropped; } us_ent;   // buf: the arena block holding the copy
static us_ent *g_us; static int g_us_n, g_us_cap;      // this submission's copies, sorted and disjoint
typedef struct { uint64_t lo, hi; } us_rng;
static us_rng *g_us_rng; static int g_us_rn, g_us_rcap;
typedef struct { uint64_t lo, hi, fence; } us_gw;      // GPU writes, with the fence of their submission
static us_gw *g_us_gw; static int g_us_gwn, g_us_gwcap;
static uint64_t g_us_subs, g_us_ranges, g_us_copies, g_us_bytes, g_us_drops, g_us_skip_gpu, g_us_ns;
static inline void args_dirty_all(void);
static size_t arena_alloc(size_t n, id<MTLBuffer> *buf);
uint64_t mtl_done_fence(void);
static int g_us_on = -1;   // -1: not read yet (tests set it directly)
static int us_on(void) {
    if (g_us_on < 0) { const char *e = getenv("DM_NVN_UBO_SNAPSHOT"); g_us_on = !(e && !strcmp(e, "0")); MLOG("uniform snapshots at submission start: %s (DM_NVN_UBO_SNAPSHOT)", g_us_on ? "on" : "off, live memory"); }
    return g_us_on;
}
// Ranges already collected in this snapshot (open addressing, four probes): the same uniform block bound for draw after draw is collected (and
// sorted) once. A range finding no free place goes through again, which the merge drops
static us_rng g_us_seen[4096];
static int us_seen(uint64_t lo, uint64_t hi) {
    uint64_t h = ((lo >> 4) ^ (hi << 7)) * 0x9E3779B97F4A7C15ull;
    for (unsigned k = 0, i = (unsigned)(h >> 52); k < 4; k++, i = (i + 1) & 4095) {
        us_rng *e = &g_us_seen[i];
        if (e->lo == lo && e->hi == hi) return 1;
        if (!e->lo) { e->lo = lo; e->hi = hi; return 0; }
    }
    return 0;
}
static void us_collect(const uint8_t *p, int depth) {
    if (depth > 32) return;
    for (uint32_t guard = 0; guard < 4000000 && p; guard++) {
        op_hdr h; memcpy(&h, p, sizeof h);
        if (h.size < 8 || (h.size & 7) || h.op == OP_END) return;
        if (h.op == OP_JUMP) { const uint8_t *t; memcpy(&t, p + 8, 8); p = t; continue; }
        if (h.op == OP_CALL) { uint64_t t; memcpy(&t, p + 8, 8); us_collect((const uint8_t *)(uintptr_t)t, depth + 1); }
        else if (h.op == OP_BIND_UBO) { const p_bind_buf *b = (const p_bind_buf *)(p + 8);
            if (b->addr && b->size && b->size <= (1u << 20) && !us_seen(b->addr, b->addr + b->size)) {
                if (g_us_rn == g_us_rcap) { g_us_rcap = g_us_rcap ? g_us_rcap * 2 : 8192; g_us_rng = realloc(g_us_rng, (size_t)g_us_rcap * sizeof *g_us_rng); }
                g_us_rng[g_us_rn++] = (us_rng){b->addr, b->addr + b->size}; } }
        p += h.size;
    }
}
static int us_rng_cmp(const void *x, const void *y) { const us_rng *a = x, *b = y; return (a->lo > b->lo) - (a->lo < b->lo); }
// The bindings by start: an LSD radix sort, 11 bits a pass, all six digit histograms from one read, and a pass whose digit is the same for every range
// skipped (the addresses share their high bits). qsort with a comparison call was 0.14-0.43 ms of the 0.3-0.9 ms a snapshot took in Tears of the
// Kingdom (4,000-11,000 bindings a submission)
static us_rng *g_us_tmp; static int g_us_tcap;
static void us_rng_sort(us_rng *a, int n) {
    if (n < 64) { qsort(a, (size_t)n, sizeof *a, us_rng_cmp); return; }
    if (g_us_tcap < n) { g_us_tcap = n * 2; g_us_tmp = realloc(g_us_tmp, (size_t)g_us_tcap * sizeof *g_us_tmp); if (!g_us_tmp) MDIE("uniform snapshot sort buffer"); }
    static uint32_t cnt[6][2048];
    memset(cnt, 0, sizeof cnt);
    for (int i = 0; i < n; i++) { uint64_t k = a[i].lo; for (int d = 0; d < 6; d++) cnt[d][(k >> (11 * d)) & 2047]++; }
    us_rng *src = a, *dst = g_us_tmp;
    for (int d = 0; d < 6; d++) {
        uint32_t *c = cnt[d]; if (c[(a[0].lo >> (11 * d)) & 2047] == (uint32_t)n) continue;   // one digit value for all: nothing to move
        for (uint32_t v = 0, acc = 0; v < 2048; v++) { uint32_t x = c[v]; c[v] = acc; acc += x; }
        for (int i = 0; i < n; i++) dst[c[(src[i].lo >> (11 * d)) & 2047]++] = src[i];
        us_rng *t = src; src = dst; dst = t;
    }
    if (src != a) memcpy(a, src, (size_t)n * sizeof *a);
}
static int us_gw_cmp(const void *x, const void *y) { const us_gw *a = x, *b = y; return (a->lo > b->lo) - (a->lo < b->lo); }
// The copies themselves, done before the replay starts as before: above US_PAR_MIN bytes split by bytes over US_PAR parts on the system's worker threads
// (one on this thread), each part whole entries
enum { US_PAR = 4, US_PAR_MIN = 256 << 10 };
static int g_us_par = -1; static uint64_t g_us_par_n;   // DM_NVN_UBO_SNAPSHOT_PAR=0: one thread; g_us_par_n: snapshots copied in parts
// A source the game made inaccessible after its pool was registered used to end the process (SIGSEGV / SIGBUS, also on the worker threads that
// copy in parts): each copy runs under a per-thread fault guard and a faulting one is dropped, so its draws read memory as without snapshots
// (MacNativeGames guards usnap_copy_one the same way after a helper thread died in about one session of twelve; MIT, written anew here)
static __thread struct { sigjmp_buf jb; uint64_t lo, hi; int armed; } t_usg;
static _Atomic uint64_t g_us_faults;
static int us_fault(void *addr, int is_write, void *uc) {   // fault hook: only a fault inside the range this thread is copying
    (void)is_write; (void)uc; uint64_t a = (uint64_t)(uintptr_t)addr;
    if (!t_usg.armed || a < t_usg.lo || a >= t_usg.hi) return 0;
    t_usg.armed = 0; siglongjmp(t_usg.jb, 1);
}
static void us_copy_range(int a, int b) {
    static dispatch_once_t hook; dispatch_once(&hook, ^{ dm_fault_hook_register(us_fault); });
    for (volatile int i = a; i < b; i++) {
        t_usg.lo = g_us[i].lo; t_usg.hi = g_us[i].hi;
        if (!sigsetjmp(t_usg.jb, 1)) { t_usg.armed = 1; memcpy(g_us[i].cpu, (const void *)(uintptr_t)g_us[i].lo, (size_t)(g_us[i].hi - g_us[i].lo)); t_usg.armed = 0; }
        else { g_us[i].dropped = 1; atomic_fetch_add(&g_us_faults, 1); }
    }
}
static void us_copy_all(void) {
    if (g_us_par < 0) { const char *e = getenv("DM_NVN_UBO_SNAPSHOT_PAR"); g_us_par = !(e && !strcmp(e, "0")); }
    uint64_t total = 0; for (int i = 0; i < g_us_n; i++) total += g_us[i].hi - g_us[i].lo;
    if (!g_us_par || total < US_PAR_MIN || g_us_n < US_PAR) { us_copy_range(0, g_us_n); return; }
    int cut[US_PAR + 1] = {0}; uint64_t acc = 0; int k = 1;
    for (int i = 0; i < g_us_n && k < US_PAR; i++) { acc += g_us[i].hi - g_us[i].lo; if (acc >= total * (uint64_t)k / US_PAR) cut[k++] = i + 1; }
    while (k <= US_PAR) cut[k++] = g_us_n;
    const int *cp = cut; g_us_par_n++;   // dispatch_apply returns when every part is done
    dispatch_apply(US_PAR, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(size_t part) { us_copy_range(cp[part], cp[part + 1]); });
}
void mtl_sub_snapshot(const uint64_t *h, int n) {   // hle_nvn.c nvnQueueSubmitCommands, after mtl_sub_begin and before the replay
    g_us_n = 0;
    if (!us_on() || !n) return;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    g_us_subs++;
    uint64_t done = mtl_done_fence(), gw_max = 0; int ng = 0;   // GPU writes of submissions not completed yet, sorted by start
    for (int i = 0; i < g_us_gwn; i++) if (g_us_gw[i].fence > done) { g_us_gw[ng++] = g_us_gw[i]; if (g_us_gw[i].hi - g_us_gw[i].lo > gw_max) gw_max = g_us_gw[i].hi - g_us_gw[i].lo; }
    g_us_gwn = ng;
    if (ng > 1) qsort(g_us_gw, (size_t)ng, sizeof *g_us_gw, us_gw_cmp);
    g_us_rn = 0; memset(g_us_seen, 0, sizeof g_us_seen);
    for (int i = 0; i < n; i++) us_collect((const uint8_t *)(uintptr_t)h[i], 0);
    if (!g_us_rn) return;
    g_us_ranges += (uint64_t)g_us_rn;
    us_rng_sort(g_us_rng, g_us_rn);
    us_rng *u = g_us_rng; int k = 0;   // merge in place; the copies stay disjoint: a range overlapping a finished copy keeps only its part beyond it
    for (int i = 1; i < g_us_rn; i++) {
        void *mb; uint64_t mo, hi = u[i].hi > u[k].hi ? u[i].hi : u[k].hi;
        if (hi <= u[k].hi) continue;
        if (u[i].lo <= u[k].hi + 256 && hi - u[k].lo <= (1u << 20) && mtl_addr(u[k].lo, hi - u[k].lo, &mb, &mo)) u[k].hi = hi;
        else { us_rng r = u[i]; if (r.lo < u[k].hi) r.lo = u[k].hi; u[++k] = r; }
    }
    int nr = k + 1;
    if (g_us_cap < nr) { g_us_cap = nr + 256; g_us = realloc(g_us, (size_t)g_us_cap * sizeof *g_us); }
    for (int i = 0; i < nr; i++) {
        void *mb; uint64_t mo, sz = u[i].hi - u[i].lo;
        if (!mtl_addr(u[i].lo, sz, &mb, &mo)) continue;   // not in one pool: read live memory
        if (ng) {   // a GPU write still running reaches it: read on the GPU timeline
            uint64_t from = u[i].lo > gw_max ? u[i].lo - gw_max : 0; int a = 0, b = ng;
            while (a < b) { int m = (a + b) / 2; if (g_us_gw[m].lo < from) a = m + 1; else b = m; }
            int hit = 0; for (int j = a; j < ng && g_us_gw[j].lo < u[i].hi; j++) if (g_us_gw[j].hi > u[i].lo) { hit = 1; break; }
            if (hit) { g_us_skip_gpu++; continue; }
        }
        id<MTLBuffer> ab; uint64_t pad = u[i].lo & 255; size_t off = arena_alloc((size_t)(sz + pad), &ab) + (size_t)pad;   // same offset modulo 256 as the original
        us_ent *c = &g_us[g_us_n++];
        c->lo = u[i].lo; c->hi = u[i].hi; c->cpu = (uint8_t *)ab.contents + off; c->gpu = ab.gpuAddress + off; c->buf = (__bridge void *)ab; c->dropped = 0;
        g_us_bytes += sz;
    }
    uint64_t uf0 = atomic_load(&g_us_faults);
    us_copy_all();
    if (atomic_load(&g_us_faults) != uf0) { static int once; if (once++ < 8) MLOG("[red] uniform snapshot: %llu source range(s) not readable (unmapped after the pool was registered): those copies dropped, their draws read memory", (unsigned long long)(atomic_load(&g_us_faults) - uf0)); }
    g_us_copies += (uint64_t)g_us_n;
    g_us_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
}
static const us_ent *us_find(uint64_t a, uint64_t n) {   // the live copy holding all of [a, a + n), or NULL
    if (!g_us_n || !a) return NULL;
    if (!n) n = 1;
    int lo = 0, hi = g_us_n;
    while (lo < hi) { int m = (lo + hi) / 2; if (g_us[m].hi <= a) lo = m + 1; else hi = m; }
    if (lo < g_us_n && g_us[lo].lo <= a && a + n <= g_us[lo].hi && !g_us[lo].dropped) return &g_us[lo];
    return NULL;
}
static void us_gw_note(uint64_t a, uint64_t n) {   // a GPU write of this submission reaches [a, a + n): the next submissions do not copy it until it completes
    int dup = 0;   // the same range written again and again (a storage buffer bound for many draws): noted once
    for (int j = g_us_gwn - 1; j >= 0 && j >= g_us_gwn - 8; j--) if (g_us_gw[j].lo == a && g_us_gw[j].hi == a + n && g_us_gw[j].fence == g_fence + 1) { dup = 1; break; }
    if (!dup) { if (g_us_gwn == g_us_gwcap) { g_us_gwcap = g_us_gwcap ? g_us_gwcap * 2 : 4096; g_us_gw = realloc(g_us_gw, (size_t)g_us_gwcap * sizeof *g_us_gw); }
                g_us_gw[g_us_gwn++] = (us_gw){a, a + n, g_fence + 1}; }
}
static void us_drop(uint64_t a, uint64_t n) {   // ... and its copies are dropped from then on: later readers see memory
    if (!n || !us_on()) return;
    us_gw_note(a, n);
    if (!g_us_n) return;
    int lo = 0, hi = g_us_n;
    while (lo < hi) { int m = (lo + hi) / 2; if (g_us[m].hi <= a) lo = m + 1; else hi = m; }
    int any = 0;
    for (int i = lo; i < g_us_n && g_us[i].lo < a + n; i++) if (!g_us[i].dropped) { g_us[i].dropped = 1; g_us_drops++; any = 1; }
    if (any) args_dirty_all();   // bindings encoded from here on read memory
}
static void us_report(uint64_t f) {   // every 300 frames
    static uint64_t p[7]; uint64_t c[7] = {g_us_subs, g_us_ranges, g_us_copies, g_us_bytes, g_us_drops, g_us_skip_gpu, g_us_ns};
    if (f % 300 || c[0] == p[0]) return;
    double ns = (double)(c[0] - p[0]);
    MLOG("uniform snapshots up to frame %llu: %llu submissions, per submission %.0f bindings in %.0f copies, %.1f KB, %.3f ms; %llu copies dropped by a GPU write of their submission, %llu ranges not copied (a GPU write of an earlier submission still running)",
         (unsigned long long)f, (unsigned long long)(c[0] - p[0]), (c[1] - p[1]) / ns, (c[2] - p[2]) / ns, (c[3] - p[3]) / ns / 1024, (c[6] - p[6]) / ns / 1e6,
         (unsigned long long)(c[4] - p[4]), (unsigned long long)(c[5] - p[5]));
    memcpy(p, c, sizeof p);
}
// Bytes [a, a + n) as the GPU will see them at this point of the replay: guest memory with the pending writes recorded before entry `upto` applied in
// order: an inline update's bytes, or what a GPU copy reads from its source as of that copy (MacNativeGames' pend_read, MIT). 0 when that is not known
// (a copy without a source, the table overflowed, copies nested too deep)
static int pend_read_x(uint64_t a, void *out, uint64_t n, int upto, int depth) {
    memcpy(out, (const void *)(uintptr_t)a, n);
    if (g_pend_over) return 0;
    for (int i = 0; i < upto; i++) {
        if (a >= g_pend_hi[i] || a + n <= g_pend_lo[i]) continue;
        uint64_t lo = MAX(a, g_pend_lo[i]), hi = MIN(a + n, g_pend_hi[i]);
        if (g_pend_data[i]) memcpy((uint8_t *)out + (lo - a), g_pend_data[i] + (lo - g_pend_lo[i]), hi - lo);
        else if (!g_pend_src[i] || depth >= 4 || !pend_read_x(g_pend_src[i] + (lo - g_pend_lo[i]), (uint8_t *)out + (lo - a), hi - lo, i, depth + 1)) return 0;
    }
    return 1;
}
static int g_nupd, g_upd_flushing;   // renamed inline uniform updates not yet in memory (see upd_log)
static void upd_apply(uint64_t lo, uint8_t *out, uint64_t n);
static int pend_read(uint64_t a, void *out, uint64_t n) {
    { const us_ent *u = us_find(a, n); if (u) { memcpy(out, u->cpu + (a - u->lo), n); if (g_nupd) upd_apply(a, out, n); return 1; } }   // not dropped: no GPU write of this submission reached it but renamed updates
    return pend_read_x(a, out, n, g_npend, 0);
}
typedef struct { uint64_t ser; uint16_t level, slice; } zskip_zero;
static zskip_zero g_zskip_zero[4096]; static int g_zskip_n, g_zskip_count;
static zskip_zero g_zskip_cand[8]; static uint8_t g_zskip_cand_ok[8];
static void zskip_clear(void);
static int tbdr_on(void);
static id g_cb;
static BENC g_blit;
static NSMutableArray<dispatch_block_t> *g_commit_blocks;
static uint64_t g_alloc_fence[ALLOC_MAX]; static uint64_t g_alloc_waits, g_alloc_grown;
int mtl_wait(uint64_t fence, uint64_t timeout_ns);
static void up_flush(void);
// The upload batch belongs only to the submit thread (the thread that called mtl_sub_begin): the batch's encoder cannot be used across threads. Every entry point asserts current thread == submit thread,
// and on mismatch prints the stack and aborts on the spot - so that 'another thread touched the batch' is exposed deterministically on Mac too, not by timing (real iOS device stuck at the main menu: the present thread flushed the submit thread's batch via q_cb).
static pthread_t g_sub_thread; static _Atomic int g_sub_thread_set;
static int on_sub_thread(void) { return atomic_load(&g_sub_thread_set) && pthread_equal(pthread_self(), g_sub_thread); }
static void up_owner_check(const char *where) {
    if (!atomic_load(&g_sub_thread_set) || on_sub_thread()) return;
    char name[64] = ""; pthread_getname_np(pthread_self(), name, sizeof name);
    MLOG("[red] upload batches belong to the submit thread only: %s called on thread '%s'", where, name);
    void *bt[32]; int n = backtrace(bt, 32); backtrace_symbols_fd(bt, n, 2);
    abort();
}
// Every command buffer created outside the replay / upload batch goes through this. On the submit thread: flush this batch's uploads first, so that commands that then read or write these textures are ordered after the uploads;
// other threads (the present thread etc.) creating a command buffer do not touch the batch: they do not read or write textures uploaded in this batch; commands that need these textures all come after this replay submission (the batch is flushed before it)
// Old-queue command buffers (readback / diagnostics / present; to be deleted once M4-4 and M4-5 are migrated away): uploads are already on the Metal 4 queue, and there is no ordering guarantee between the two queues -
// wait for the upload to complete after flushing it, and only then can the old queue read the upload result (mtl_read_texels waited first and flushed afterwards, the readback beat the upload, 4 failures on t_nvn upload content)
static id<MTLCommandBuffer> q_cb(void) { if (on_sub_thread()) { up_flush(); up_wait_zero(&g_up_pending); } return [g_q commandBuffer]; }
static post_op *g_post; static int g_npost, g_postcap;
// One autorelease pool per submission: submissions run on a guest thread (long-lived, no run loop, never drains the implicit pool), so objects autoreleased in the Metal replay
// (command buffers, encoders, pass descriptors, etc.) are never released unless put in a pool. Measured on the character select screen of a real iOS device: the host heap grows by about 47 objects per frame, 0.22 MiB/s.
void *objc_autoreleasePoolPush(void); void objc_autoreleasePoolPop(void *);
static void *g_sub_pool;
static int g_ruler_truth = -1, g_ruler_pending;
static int tbdr_on(void);

static uint64_t g_sub_serial;   // Submission index (used by the parallel precompile's 'predict only once per submission')
static void fin_drain(void);
static void chunk_reset(void);   // mid-submission commits (defined with the render pass state)
static void pg_sub_begin(uint64_t fence); static void pg_commit(id fb);   // DM_NVN_PASSGPU
static void pkg_census(void);   // DM_NVN_COUNTS: uploaded textures by last use
void mtl_sub_begin(void) {
    mtl_init(); g_sub_serial++;
    if (tbdr_on() == 0 && g_ruler_pending) { g_ruler_truth = 0; g_ruler_pending = 0; MLOG("DM_NVN_RULER: switched to the measured mode"); }
    // A pool of their own: they run before the submission's pool below, on the game's submit thread, which has none and never drains one. The
    // retired objects they release went into the thread's implicit pool and lived for good (nxnative 0fc0ce4: Metroid Dread's GPU memory grew by
    // gigabytes; t_retire)
    @autoreleasepool { defer_drain(); defer_reset(); fin_drain(); warm_claim(); }
    if (g_cb) MDIE("submit re-entered");
    g_sub_thread = pthread_self(); atomic_store(&g_sub_thread_set, 1);
    atomic_store(&g_last_commit_error, 0);
    g_sub_pool = objc_autoreleasePoolPush();
#if DM_NVN_M3
    g_cb = [g_q commandBuffer];
#else
    g_cb = [g_dev newCommandBuffer];
#endif
    // Do not wait for the GPU mid-frame (hot real device: with a fixed rotation of 3, when the GPU cannot keep up every frame blocks here, and the submit thread runs at low frequency after waking, instruction count −18% but CPU time +49%):
    // pick an allocator the GPU has finished with; if all are in use create a new one; only at the cap wait for the oldest one. How far ahead it runs is bounded by the wait where the game acquires the swapchain texture, same as the old interface.
    int alloc_i = -1; uint64_t done = g_done;
    for (int i = 0; i < g_alloc_n; i++) if (g_alloc_fence[i] <= done) { alloc_i = i; break; }
#if DM_NVN_M3
    if (alloc_i < 0 && g_alloc_n < ALLOC_MAX) { alloc_i = g_alloc_n++; g_alloc_grown++; }
#else
    if (alloc_i < 0 && g_alloc_n < ALLOC_MAX) { NSError *ae = nil; MTL4CommandAllocatorDescriptor *ad = [MTL4CommandAllocatorDescriptor new];
        g_alloc4[g_alloc_n] = [g_dev newCommandAllocatorWithDescriptor:ad error:&ae]; if (!g_alloc4[g_alloc_n]) MDIE("failed to create new MTL4CommandAllocator: %s", ae.localizedDescription.UTF8String);
        alloc_i = g_alloc_n++; g_alloc_grown++; }
#endif
    if (alloc_i < 0) { alloc_i = 0; for (int i = 1; i < g_alloc_n; i++) if (g_alloc_fence[i] < g_alloc_fence[alloc_i]) alloc_i = i; g_alloc_waits++; mtl_wait(g_alloc_fence[alloc_i], UINT64_MAX); }
    g_alloc_cur = alloc_i;
#if !DM_NVN_M3
    [g_alloc4[alloc_i] reset];
    [g_cb beginCommandBufferWithAllocator:g_alloc4[alloc_i]];
#endif
    g_commit_blocks = [NSMutableArray array];
    pg_sub_begin(g_fence + 1);
    id<MTLBuffer> vis_prev = g_vis;   // the previous submission's: an overflow buffer is retired below
    g_cnt_sub_ts = 0;
    if (g_cnt_on > 0 && g_sub_serial % 300 == 0) pkg_census();
    g_npost = 0; g_vis = nil; g_vis_n = 0; g_vis_cur = -1; pend_begin(mtl_done_fence());
    zskip_clear(); g_zskip_count = 0; chunk_reset();
    int pick = -1;
    for (int i = 0; i < g_vis_ring_n; i++) if (g_vis_ring[i].fence <= g_done) { pick = i; break; }
    if (pick < 0 && g_vis_ring_n < 4) pick = g_vis_ring_n++;
    if (pick < 0) { uint64_t oldest = UINT64_MAX; for (int i = 0; i < 4; i++) if (g_vis_ring[i].fence < oldest) { oldest = g_vis_ring[i].fence; pick = i; } if (oldest > g_done) mtl_wait(oldest, UINT64_MAX); }
    g_vis_ring_i = pick; g_vis_ring[pick].fence = UINT64_MAX;
    if (!g_vis_ring[pick].buf) { g_vis_ring[pick].buf = [g_dev newBufferWithLength:VIS_SLOTS * 8 options:MTLResourceStorageModeShared]; res_add(g_vis_ring[pick].buf); }
    if (vis_prev && !vis_in_ring(vis_prev)) defer_obj_release(vis_prev);   // the overflow buffer left by the previous submission (see the place with g_vis_n >= VIS_SLOTS): retire it, otherwise it stays in the residency set forever (it was read after g_vis was cleared, and never retired)
    g_vis = g_vis_ring[pick].buf;
    vis_recycle(g_vis);
    void arena_begin(void); arena_begin();
}

static void rp_end(void);
// Metal 4 conservative barriers (first version): a consumer barrier at the start of an encoder (all prior work → this encoder) and a producer barrier at the end (this encoder and earlier → later encoders).
// Only the one at the start is not enough: t_rt_range 'pass 1 → pass 2 → copy' read back black, and after adding the end barrier it is 19/19. Old-queue encoders (upload / diagnostics / present) do not go through these barriers.
#if DM_NVN_M3
static inline void m4_end(id e) { [e endEncoding]; }   // the older API has no explicit barriers: dependencies come from useResource declarations plus the system's automatic tracking
static inline void m3_rbuf(id<MTLRenderCommandEncoder> e, int vertex, NSUInteger i, uint64_t gpu) {
    NSUInteger off; id<MTLBuffer> b = m3_buf(gpu, &off); if (gpu && !b) { { static int n_; if (!n_++) MLOG("[red] " "legacy API bind: GPU address %#llx is not in any registered buffer (slot %lu)", (unsigned long long)gpu, (unsigned long)i); } return; }
    if (vertex) [e setVertexBuffer:b offset:off atIndex:i]; else [e setFragmentBuffer:b offset:off atIndex:i];
}
#else
static inline void m4_end(id e) {
    if ([e conformsToProtocol:@protocol(MTL4CommandEncoder)]) [(id<MTL4CommandEncoder>)e barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
}
#endif
// Render state already set on the current encoder (MacNativeGames' es_* filter, MIT; written anew here): the replay sets viewport, scissor, cull,
// winding, fill, depth bias, depth clip, stencil reference and blend color for every draw, nearly always unchanged (about 30,000 encoder calls a
// frame in Tears of the Kingdom). The cache belongs to one encoder: reset where a render encoder opens and where it ends (t_esfilter)
static struct { __unsafe_unretained id en; MTLViewport vp; MTLScissorRect sc; int cull, wind, fill, clip; float bias[3], bc[4]; uint32_t sref; uint8_t has_vp, has_sc, has_bias, has_bc, has_sref; } g_es;
static uint64_t g_es_sets, g_es_skips;
static inline void es_reset(id e) { memset(&g_es, 0, sizeof g_es); g_es.cull = g_es.wind = g_es.fill = g_es.clip = -1; g_es.en = e; }
static inline int es_mine(id e) { if (g_es.en != e) es_reset(e); return 1; }
void mtl_es_stats(uint64_t *sets, uint64_t *skips) { *sets = g_es_sets; *skips = g_es_skips; }
#if DM_NVN_M3
static inline RENC enc_r_begin(RPD *d) { RENC e = [g_cb renderCommandEncoderWithDescriptor:d]; es_reset(e); return e; }
static inline void enc_r_end(id e) { m4_end(e); es_reset(nil); }
#define RS(call) do {} while (0)   // no encode stage on the older API
static inline void rs_sync(void) {}
static inline void rs_sub_end(void) {}
#else
#include "nvn_render_stream.h"
#define RS(call) do { if (rs_mine(e)) { call; return; } } while (0)   // a pass the encode stage owns: the call becomes a packet
static inline RENC enc_r_begin(RPD *d) { if (rs_stream_pass()) { id s = rs_pass_begin(d, g_cb); es_reset(s); return s; }
    RENC e = [g_cb renderCommandEncoderWithDescriptor:d]; es_reset(e); [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice]; [e setArgumentTable:g_vt atStages:MTLRenderStageVertex]; [e setArgumentTable:g_ft atStages:MTLRenderStageFragment]; return e; }
static inline void enc_r_end(id e) { if (rs_mine(e)) rs_pass_end(); else m4_end(e); es_reset(nil); }
#endif
static inline void enc_r_pso(RENC e, id<MTLRenderPipelineState> p) { RS(rs_obj(RS_PSO, p)); [e setRenderPipelineState:p]; }
static inline void enc_r_dss(RENC e, id<MTLDepthStencilState> s) { RS(rs_obj(RS_DSS, s)); [e setDepthStencilState:s]; }
static inline void enc_r_store(RENC e, int which, MTLStoreAction a, NSUInteger i) {   // which: 0 colour attachment i, 1 depth, 2 stencil (deferred store actions)
    RS(rs_op(RS_STORE, (uint64_t)which, (uint64_t)a, i));
    if (which == 1) [e setDepthStoreAction:a]; else if (which == 2) [e setStencilStoreAction:a]; else [e setColorStoreAction:a atIndex:i]; }
#define ES_SAME(cond) do { es_mine(e); if (cond) { g_es_skips++; return; } g_es_sets++; } while (0)
static inline void enc_r_viewport(RENC e, MTLViewport v) { ES_SAME(g_es.has_vp && !memcmp(&g_es.vp, &v, sizeof v)); g_es.vp = v; g_es.has_vp = 1; RS(rs_bytes(RS_VIEWPORT, &v, sizeof v)); [e setViewport:v]; }
static inline void enc_r_scissor(RENC e, MTLScissorRect r) { ES_SAME(g_es.has_sc && !memcmp(&g_es.sc, &r, sizeof r)); g_es.sc = r; g_es.has_sc = 1; RS(rs_bytes(RS_SCISSOR, &r, sizeof r)); [e setScissorRect:r]; }
static inline void enc_r_cull(RENC e, MTLCullMode m) { ES_SAME(g_es.cull == (int)m); g_es.cull = (int)m; RS(rs_op(RS_CULL, m, 0, 0)); [e setCullMode:m]; }
static inline void enc_r_winding(RENC e, MTLWinding w) { ES_SAME(g_es.wind == (int)w); g_es.wind = (int)w; RS(rs_op(RS_WINDING, w, 0, 0)); [e setFrontFacingWinding:w]; }
static inline void enc_r_fill(RENC e, MTLTriangleFillMode m) { ES_SAME(g_es.fill == (int)m); g_es.fill = (int)m; RS(rs_op(RS_FILL, m, 0, 0)); [e setTriangleFillMode:m]; }
static inline void enc_r_depth_bias(RENC e, float u, float s, float c) { float b[3] = {u, s, c}; ES_SAME(g_es.has_bias && !memcmp(g_es.bias, b, sizeof b)); memcpy(g_es.bias, b, sizeof b); g_es.has_bias = 1; RS(rs_bytes(RS_BIAS, b, sizeof b)); [e setDepthBias:u slopeScale:s clamp:c]; }
static inline void enc_r_depth_clip(RENC e, BOOL v) { MTLDepthClipMode m = v ? MTLDepthClipModeClip : MTLDepthClipModeClamp; ES_SAME(g_es.clip == (int)m); g_es.clip = (int)m; RS(rs_op(RS_CLIP, m, 0, 0)); [e setDepthClipMode:m]; }
static inline void enc_r_stencil_ref(RENC e, uint32_t f, uint32_t b) { (void)b; ES_SAME(g_es.has_sref && g_es.sref == f); g_es.sref = f; g_es.has_sref = 1; RS(rs_op(RS_STENCIL, f, 0, 0)); [e setStencilReferenceValue:f]; }
static inline void enc_r_blend_color(RENC e, float r, float g, float b, float a) { float c[4] = {r, g, b, a}; ES_SAME(g_es.has_bc && !memcmp(g_es.bc, c, sizeof c)); memcpy(g_es.bc, c, sizeof c); g_es.has_bc = 1; RS(rs_bytes(RS_BLEND, c, sizeof c)); [e setBlendColorRed:r green:g blue:b alpha:a]; }
static inline void enc_r_visibility(RENC e, MTLVisibilityResultMode m, NSUInteger o) { RS(rs_op(RS_VISIBILITY, m, o, 0)); [e setVisibilityResultMode:m offset:o]; }
static inline void enc_r_layer(RENC e, uint32_t off) { RS(rs_op(RS_LAYER, off, 0, 0)); MTLVertexAmplificationViewMapping m = {0, off}; [e setVertexAmplificationCount:1 viewMappings:&m]; }   // the draws go to layer slice + off
#if DM_NVN_M3
static inline void enc_r_vbuf(RENC e, NSUInteger i, uint64_t gpu) { m3_rbuf(e, 1, i, gpu); }
static inline void enc_r_args(RENC e, MTLRenderStages s, uint64_t gpu, NSUInteger i) { m3_rbuf(e, s == MTLRenderStageVertex, i, gpu); }
#else
// The argument tables: once the encode stage exists it applies every address (in order with its draws, which read the tables when encoded)
static inline void enc_r_vbuf(RENC e, NSUInteger i, uint64_t gpu) { (void)e; if (g_rs_created) { rs_op(RS_ADDRESS, 0, i, gpu); return; } [g_vt setAddress:gpu atIndex:i]; }
static inline void enc_r_args(RENC e, MTLRenderStages s, uint64_t gpu, NSUInteger i) { (void)e; if (g_rs_created) { rs_op(RS_ADDRESS, s != MTLRenderStageVertex, i, gpu); return; } [(s == MTLRenderStageVertex ? g_vt : g_ft) setAddress:gpu atIndex:i]; }
#endif
static inline void enc_r_draw_instanced(RENC e, MTLPrimitiveType p, NSUInteger v, NSUInteger n, NSUInteger i, NSUInteger b) {
    RS(rs_put((rs_packet){.op = RS_INSTANCED, .u = {p, v, n, i, b}}, 1)); [e drawPrimitives:p vertexStart:v vertexCount:n instanceCount:i baseInstance:b]; }
#if DM_NVN_M3
static inline void enc_r_draw_indexed(RENC e, MTLPrimitiveType p, NSUInteger n, MTLIndexType t, uint64_t gpu, NSUInteger len, NSUInteger i, NSInteger bv, NSUInteger bi) { (void)len; if (!n) return; NSUInteger off; id<MTLBuffer> b = m3_buf(gpu, &off); if (!b) { { static int n_; if (!n_++) MLOG("[red] " "legacy API draw: index buffer address %#llx is not in any registered buffer", (unsigned long long)gpu); } return; } [e drawIndexedPrimitives:p indexCount:n indexType:t indexBuffer:b indexBufferOffset:off instanceCount:i baseVertex:bv baseInstance:bi]; }
#else
static inline void enc_r_draw_indexed(RENC e, MTLPrimitiveType p, NSUInteger n, MTLIndexType t, uint64_t gpu, NSUInteger len, NSUInteger i, NSInteger bv, NSUInteger bi) {
    RS(rs_put((rs_packet){.op = RS_INDEXED, .u = {p, n, t, gpu, len, i, (uint64_t)bv, bi}}, 1)); [e drawIndexedPrimitives:p indexCount:n indexType:t indexBuffer:gpu indexBufferLength:len instanceCount:i baseVertex:bv baseInstance:bi]; }
#endif
#if DM_NVN_M3
static inline CENC enc_c_begin(MTLComputePassDescriptor *d) { return d ? [g_cb computeCommandEncoderWithDescriptor:d] : [g_cb computeCommandEncoder]; }
#else
static inline CENC enc_c_begin(MTLComputePassDescriptor *d) { (void)d; rs_sync(); CENC e = [g_cb computeCommandEncoder]; [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice]; [e setArgumentTable:g_ct]; return e; }
#endif
static inline id<MTLComputeCommandEncoder> enc_c_begin_concurrent(id<MTLCommandBuffer> cb) { return [cb computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent]; }
static inline void enc_c_end(id e) { m4_end(e); }
static inline void enc_c_pso(id e, id<MTLComputePipelineState> p) { [e setComputePipelineState:p]; }
#if DM_NVN_M3
static inline void enc_c_args(id e, uint64_t gpu, NSUInteger i) { NSUInteger off; id<MTLBuffer> b = m3_buf(gpu, &off); if (gpu && !b) { { static int n_; if (!n_++) MLOG("[red] " "legacy API compute bind: GPU address %#llx is not in any registered buffer (slot %lu)", (unsigned long long)gpu, (unsigned long)i); } return; } [(id<MTLComputeCommandEncoder>)e setBuffer:b offset:off atIndex:i]; }
#else
static inline void enc_c_args(id e, uint64_t gpu, NSUInteger i) { (void)e; [g_ct setAddress:gpu atIndex:i]; }
#endif
static inline void enc_c_dispatch(id e, MTLSize n, MTLSize t) { [e dispatchThreadgroups:n threadsPerThreadgroup:t]; }
#if DM_NVN_M3
static inline id enc_b_begin(id cb) { return [cb blitCommandEncoder]; }
#else
static inline id enc_b_begin(id cb) { if (cb == g_cb) rs_sync(); return [cb respondsToSelector:@selector(beginCommandBufferWithAllocator:)] ? [cb computeCommandEncoder] : [cb blitCommandEncoder]; }
#endif
static inline void enc_b_end(id e) { m4_end(e); }
static inline void enc_b_copy_buffer(id e, id<MTLBuffer> s, NSUInteger so, id<MTLBuffer> d, NSUInteger doff, NSUInteger n) { [e copyFromBuffer:s sourceOffset:so toBuffer:d destinationOffset:doff size:n]; }
static inline void enc_b_copy_buffer_texture(id e, id<MTLBuffer> s, NSUInteger so, NSUInteger row, NSUInteger img, MTLSize z, id<MTLTexture> d, NSUInteger sl, NSUInteger lv, MTLOrigin o) { [e copyFromBuffer:s sourceOffset:so sourceBytesPerRow:row sourceBytesPerImage:img sourceSize:z toTexture:d destinationSlice:sl destinationLevel:lv destinationOrigin:o]; }
static inline void enc_b_copy_texture_buffer(id e, id<MTLTexture> s, NSUInteger sl, NSUInteger lv, MTLOrigin o, MTLSize z, id<MTLBuffer> d, NSUInteger doff, NSUInteger row, NSUInteger img) { [e copyFromTexture:s sourceSlice:sl sourceLevel:lv sourceOrigin:o sourceSize:z toBuffer:d destinationOffset:doff destinationBytesPerRow:row destinationBytesPerImage:img]; }
static inline void enc_b_copy_texture(id e, id<MTLTexture> s, NSUInteger sl, NSUInteger lv, MTLOrigin so, MTLSize z, id<MTLTexture> d, NSUInteger dl, NSUInteger dv, MTLOrigin doo) { [e copyFromTexture:s sourceSlice:sl sourceLevel:lv sourceOrigin:so sourceSize:z toTexture:d destinationSlice:dl destinationLevel:dv destinationOrigin:doo]; }
static void blit_note(void);   // Per-pass dump: a copy / buffer update ended the render pass (defined after PD)
static void upd_flush(void); static void upd_sub_end(void);
static void chunk_maybe_split(void);   // mid-submission commits (defined with the render pass state)
#if DM_NVN_M3
static BENC blit(void) { if (g_nupd && !g_upd_flushing) upd_flush(); blit_note(); rp_end(); if (!g_blit) { chunk_maybe_split(); g_blit = enc_b_begin(g_cb); } return g_blit; }
#else
// A reused blit encoder also needs a barrier between two copies: Metal 4 does not keep the commands of one encoder in recording order, and the
// queue barrier at encoder creation covers only earlier encoders (Apple: "Synchronizing stages within a pass"). Without it a write-then-read or two
// writes to one range may overlap (seen upstream in t_nvn 5c, once in three runs). The blit encoder is a compute encoder on Metal 4: both stages
static BENC blit(void) { if (g_nupd && !g_upd_flushing) upd_flush(); blit_note(); rp_end();   // logged uniform updates reach memory before any copy or dispatch
    if (!g_blit) { chunk_maybe_split(); g_blit = enc_b_begin(g_cb); [g_blit barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice]; }
    else [g_blit barrierAfterEncoderStages:MTLStageBlit | MTLStageDispatch beforeEncoderStages:MTLStageBlit | MTLStageDispatch visibilityOptions:MTL4VisibilityOptionDevice];
    return g_blit; }
#endif

void mtl_sub_copy(uint64_t src, uint64_t dst, uint64_t n) {
    pend_note(dst, n, NULL, src);
    us_drop(dst, n);   // later readers see the copied bytes in memory
    void *sb, *db; uint64_t so, dof;
    if (!mtl_addr(src, n, &sb, &so) || !mtl_addr(dst, n, &db, &dof))
        MDIE("buffer copy address not in any memory pool src=%#llx dst=%#llx n=%#llx", (unsigned long long)src, (unsigned long long)dst, (unsigned long long)n);
    enc_b_copy_buffer(blit(), (__bridge id<MTLBuffer>)sb, so, (__bridge id<MTLBuffer>)db, dof, n);
}

// Inline uniform update (UpdateUniformBuffer): the data is copied into the host's own shared ring when the command is replayed, and from there in
// order to the destination. It used to be copied from command memory only when the GPU ran the copy: a game that recycles that command memory
// first hands over the bytes of its next commands instead (nxnative saw it in SMBW, seedds, MIT; Tears of the Kingdom reuses command memory as well)
static id<MTLBuffer> g_ubs_buf; static size_t g_ubs_off, g_ubs_size;
static void ring_put(const void *data, uint64_t n, __unsafe_unretained id<MTLBuffer> *rb, size_t *ro);
static const uint8_t *update_to(const void *data, uint64_t n, id<MTLBuffer> db, uint64_t dof) {   // returns the bytes' copy in the ring
    __unsafe_unretained id<MTLBuffer> rb; size_t ro; ring_put(data, n, &rb, &ro);
    enc_b_copy_buffer(blit(), rb, ro, db, dof, n);
    return (const uint8_t *)rb.contents + ro;
}
static void ring_put(const void *data, uint64_t n, __unsafe_unretained id<MTLBuffer> *rb, size_t *ro) {
    size_t need = (n + 15u) & ~(size_t)15u;
    if (!g_ubs_buf || g_ubs_off + need > g_ubs_size) {
        if (g_ubs_buf) defer_obj_release(g_ubs_buf);   // retired: copies already encoded still read it, released (and made non-resident) after this submission completes
        g_ubs_size = MAX((size_t)1 << 20, need);
        g_ubs_buf = [g_dev newBufferWithLength:g_ubs_size options:MTLResourceStorageModeShared];
        if (!g_ubs_buf) MDIE("uniform update ring allocation failed %#zx", g_ubs_size);
        res_add(g_ubs_buf); g_ubs_off = 0;
    }
    memcpy((uint8_t *)g_ubs_buf.contents + g_ubs_off, data, n);
    *rb = g_ubs_buf; *ro = g_ubs_off;
    g_ubs_off += need;
}
static int ub_rename_on(void); static void upd_log(uint64_t lo, uint64_t hi, const uint8_t *data);
void mtl_sub_update(const void *data, uint64_t dst, uint64_t n) {
    if (!n) return;
    void *db; uint64_t dof;
    if (!mtl_addr(dst, n, &db, &dof)) MDIE("uniform update destination not in any memory pool dst=%#llx n=%#llx", (unsigned long long)dst, (unsigned long long)n);
    if (ub_rename_on()) {   // renamed: logged, the render pass stays open (upd_log)
        __unsafe_unretained id<MTLBuffer> rb; size_t ro; ring_put(data, n, &rb, &ro);
        const uint8_t *bytes = (const uint8_t *)rb.contents + ro;
        pend_note(dst, n, bytes, 0); upd_log(dst, dst + n, bytes);
        return;
    }
    us_drop(dst, n);   // the update reaches memory on the GPU timeline; later readers read it there
    pend_note(dst, n, update_to(data, n, (__bridge id<MTLBuffer>)db, dof), 0);   // its bytes as copied into the ring (command memory may be reused once the submission is in)
}
static void post(post_op o) {
    if (g_npost == g_postcap) { g_postcap = g_postcap ? g_postcap * 2 : 64; g_post = realloc(g_post, g_postcap * sizeof *g_post); }
    g_post[g_npost++] = o;
}
void mtl_sub_event(volatile uint32_t *val, uint32_t mode, uint32_t v) { post((post_op){1, val, mode, v, 0, 0, NULL}); }
void mtl_sub_counter(uint64_t addr, uint32_t type) { post((post_op){2, NULL, 0, 0, addr, type, NULL}); }
void mtl_counter_stats(uint64_t rep[32], uint64_t rst[32]) { memcpy(rep, g_cnt_report, sizeof g_cnt_report); memcpy(rst, g_cnt_reset, sizeof g_cnt_reset); }
void mtl_vis_state(int *open, uint64_t *folded) { *open = g_nvs; *folded = g_vis_folded; }   // samples-passed slots since the last reset, slots folded so far (power line)

// Counter timestamps: 19.2 MHz ticks of the guest clock, the one behind the guest's system tick (svc GetSystemTick / cntpct). On the console the GPU
// timer and the CPU's system counter share one time base, and games subtract one from the other: Tears of the Kingdom's frame-rate controller takes
// nvnDeviceGetTimestampInNanoseconds of the frame's last report, converts it with nn::os::ConvertToTick and subtracts the frame's start tick
// (main 0x2b3cff8). CLOCK_MONOTONIC counts the Mac's sleep too, mach_absolute_time does not: after 25 hours of sleep the "GPU time" came out as
// 25 hours, and the controller held the game at present interval 3 (20 fps) with CPU and GPU idle most of the frame
uint64_t guest_ns(void);
static uint64_t gpu_ticks(void) {   // DM_NVN_TS_LATE_US=<n>: reports n µs later (the game sees a slower GPU: what does it do then)
    static int64_t late = -1; if (late < 0) { const char *e = getenv("DM_NVN_TS_LATE_US"); late = e ? atoll(e) * 1000 : 0; if (late) MLOG("DM_NVN_TS_LATE_US: counter timestamps %lld µs late", (long long)(late / 1000)); }
    return (guest_ns() + (uint64_t)late) * 12 / 625; }

// ---------- Boot instrumentation (DM_BOOTPROF=1): metallib loading, pipeline creation (both happen synchronously during replay on the submit thread), texture upload, first-frame present ----------
static uint64_t bp_now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }
static uint64_t g_bp_t0;   // Time of process start (when this module is loaded)
__attribute__((constructor)) static void bp_t0(void) { g_bp_t0 = bp_now(); }
static int bootprof(void) { static int v = -1; if (v < 0) v = getenv("DM_BOOTPROF") != NULL; return v; }
static uint64_t g_bp_lib_n, g_bp_lib_ns, g_bp_pso_n, g_bp_pso_ns, g_bp_up_bytes, g_bp_first_present;
static uint64_t g_up_total_ns;   // Cumulative upload time (same source as the per-frame @upload_ms)
// ---------- Per-frame GPU time aggregation ----------
#define GRING 1024
static struct { _Atomic uint64_t frame, ns, t0, t1; _Atomic int pending; } g_gpu[GRING];   // t0 / t1: the frame's earliest GPUStart / latest GPUEnd (mach absolute time, ns)
// The frame's GPU time is the union of its command buffers' spans: Apple GPUs start a buffer while the one before it runs, so the plain sum (ns) counted
// the overlap twice (LASRecomp PR #197: summed 13-17 ms against a union of 6.5-7 ms). The spans of the last GIVR frames are kept (the time is read 8
// frames late); a full list is merged, and if no two spans overlap the two closest are joined (their gap is counted, the only overestimate)
#define GIVR 32
enum { GIV = 128 };
static struct { uint64_t frame; uint32_t n; uint64_t iv[GIV][2]; os_unfair_lock lk; } g_giv[GIVR];
static int giv_cmp(const void *a, const void *b) { const uint64_t *x = a, *y = b; return x[0] < y[0] ? -1 : x[0] > y[0]; }
static uint32_t giv_merge(uint64_t (*iv)[2], uint32_t n) {   // sort by start and join overlapping spans in place; returns the new count
    if (n < 2) return n;
    qsort(iv, n, sizeof *iv, giv_cmp);
    uint32_t m = 0;
    for (uint32_t i = 1; i < n; i++) { if (iv[i][0] <= iv[m][1]) { if (iv[i][1] > iv[m][1]) iv[m][1] = iv[i][1]; } else { m++; iv[m][0] = iv[i][0]; iv[m][1] = iv[i][1]; } }
    return m + 1;
}
static uint64_t giv_union_ns(uint64_t (*iv)[2], uint32_t *n) { *n = giv_merge(iv, *n); uint64_t s = 0; for (uint32_t i = 0; i < *n; i++) s += iv[i][1] - iv[i][0]; return s; }
static void giv_add(uint64_t f, uint64_t s0, uint64_t s1) {
    unsigned k = f % GIVR; os_unfair_lock_lock(&g_giv[k].lk);
    if (g_giv[k].frame != f) { g_giv[k].frame = f; g_giv[k].n = 0; }
    if (g_giv[k].n == GIV) g_giv[k].n = giv_merge(g_giv[k].iv, GIV);
    if (g_giv[k].n == GIV) {   // still full: join the two closest neighbours
        uint32_t bi = 0; uint64_t bg = UINT64_MAX;
        for (uint32_t i = 0; i + 1 < GIV; i++) { uint64_t gap = g_giv[k].iv[i + 1][0] - g_giv[k].iv[i][1]; if (gap < bg) { bg = gap; bi = i; } }
        g_giv[k].iv[bi][1] = g_giv[k].iv[bi + 1][1]; memmove(&g_giv[k].iv[bi + 1], &g_giv[k].iv[bi + 2], (GIV - bi - 2) * sizeof g_giv[k].iv[0]); g_giv[k].n--;
    }
    g_giv[k].iv[g_giv[k].n][0] = s0; g_giv[k].iv[g_giv[k].n][1] = s1; g_giv[k].n++;
    os_unfair_lock_unlock(&g_giv[k].lk);
}
static _Atomic uint64_t g_cur_frame;
// ---------- Same-process alternating measurement (DM_NVN_UB, off by default: without the environment variable the code below only adds one 'is it enabled' check) ----------
// On a hot real device the system keeps adjusting power / frequency, and segment comparison (segments A and B each run for a minute) cannot resolve differences of <10%; within the same run, toggle by phase in turn and take differences of adjacent phase pairs, so the drift cancels.
// DM_NVN_UB="name=item,item;name=item", one phase every DM_NVN_UB_N frames (default 180, minimum 60): even phases = baseline (nothing changed), odd phases take one category in turn. Each item of a category:
//   @set:<global variable name>=<value>   on entering the phase set this int global variable to the value, on leaving restore it (address found by symbol name; switches to be used on a real device must have a line added to the registration table below)
//   <fragment shader key prefix> or *   the phase drops all draws of these fragment shaders (the picture will be wrong; it only measures 'how much this kind of draw is worth'; a nearly idle category needs a round of its own)
// Readings: each phase discards its first 45 frames (transition + present lag); for the remaining frames, the mean of the actual present interval (same source as perf.txt) and the frame counts in the three buckets 16.7 / 25 / ≥33 ms, one log line "UB present".
static int g_ub_n = -1, g_ub_N = 180; static _Atomic int g_ub_cur = -1; static char g_ub_name[16][16], g_ub_keys[16][16][48]; static int g_ub_nk[16];
static _Atomic int g_ubp_on, g_ubp_c[4]; static _Atomic uint64_t g_ubp_sum_us;
void mtl_ub_present(double iv) {   // Called once per frame by the present thread: actual present interval in ms (−1 = dropped, 0 = no reading)
    if (!atomic_load(&g_ubp_on) || iv == 0) return;
    if (iv < 0) { atomic_fetch_add(&g_ubp_c[3], 1); return; }
    atomic_fetch_add(&g_ubp_c[iv <= 20.8 ? 0 : iv <= 29.2 ? 1 : 2], 1); atomic_fetch_add(&g_ubp_sum_us, (uint64_t)(iv * 1000));
}
// Registered runtime switches: name → address. Main-program symbols of an iOS release build are not in the dynamic symbol table and dlsym cannot find them (in the first real-device round all four categories were "global variable not found" and the whole round was wasted),
// so a switch to be measured on a real device must have a line added here; on Mac / in unit tests unregistered ones are still looked up by symbol name.
static int *ub_var(const char *nm) {
    extern int g_dm_present_link;
    static const struct { const char *n; int *p; } t[] = { {"g_dm_present_link", &g_dm_present_link} };
    for (size_t i = 0; i < sizeof t / sizeof t[0]; i++) if (!strcmp(nm, t[i].n)) return t[i].p;
    return dlsym(RTLD_DEFAULT, nm);
}
static void ub_frame(uint64_t f) {
    if (g_ub_n < 0) { g_ub_n = 0; const char *e = getenv("DM_NVN_UB"), *n = getenv("DM_NVN_UB_N"); if (n && atoi(n) >= 60) g_ub_N = atoi(n);
        for (const char *q = e; q && *q && g_ub_n < 16; ) { const char *eq = strchr(q, '='), *end = strchr(q, ';'); if (!end) end = q + strlen(q); if (!eq || eq > end) break;
            int c = g_ub_n++; size_t l = (size_t)(eq - q); if (l > 15) l = 15; memcpy(g_ub_name[c], q, l);
            for (const char *k = eq + 1; k < end && g_ub_nk[c] < 16; ) { size_t kl = 0; while (k + kl < end && k[kl] != ',') kl++; size_t cl = kl > 47 ? 47 : kl; memcpy(g_ub_keys[c][g_ub_nk[c]++], k, cl); k += kl; if (k < end) k++; }
            q = *end ? end + 1 : end; }
        if (g_ub_n) MLOG("DM_NVN_UB: %d categories, %d frames per phase (alternating measurement in one process; phases that drop draws render incorrectly)", g_ub_n, g_ub_N); }
    if (!g_ub_n) return;
    uint64_t ph = f / (uint64_t)g_ub_N, r = f % (uint64_t)g_ub_N;
    if (r == 45) { for (int i = 0; i < 4; i++) atomic_store(&g_ubp_c[i], 0); atomic_store(&g_ubp_sum_us, 0); atomic_store(&g_ubp_on, 1); }
    if (r != 0) return;
    if (f && atomic_load(&g_ubp_on)) { atomic_store(&g_ubp_on, 0); uint64_t pp = ph - 1; int pc = (pp & 1) ? (int)((pp / 2) % (uint64_t)g_ub_n) : -1;
        int c0 = atomic_load(&g_ubp_c[0]), c1 = atomic_load(&g_ubp_c[1]), c2 = atomic_load(&g_ubp_c[2]), c3 = atomic_load(&g_ubp_c[3]), n_ = c0 + c1 + c2;
        MLOG("UB present %llu %s frames %d avg %.3f ms 2-tick %d 3-tick %d 4+tick %d dropped %d", (unsigned long long)pp, pc < 0 ? "base" : g_ub_name[pc], n_, n_ ? atomic_load(&g_ubp_sum_us) / 1000.0 / n_ : 0.0, c0, c1, c2, c3); }
    int nc = (ph & 1) ? (int)((ph / 2) % (uint64_t)g_ub_n) : -1;
    static int *sp[16]; static int sv[16], ns;   // Variables set by the previous phase: restore first
    for (int i = 0; i < ns; i++) *sp[i] = sv[i]; ns = 0;
    for (int i = 0; nc >= 0 && i < g_ub_nk[nc] && ns < 16; i++) { const char *k = g_ub_keys[nc][i]; if (strncmp(k, "@set:", 5)) continue;
        char nm[48]; const char *eq = strchr(k, '='); if (!eq) continue; size_t l = (size_t)(eq - (k + 5)); if (l >= sizeof nm) continue; memcpy(nm, k + 5, l); nm[l] = 0;
        int *a_ = ub_var(nm); static int bad, ok;
        if (!a_) { if (bad++ < 8) MLOG("[red] DM_NVN_UB: global variable not found: %s (on a real device it must first be registered in the ub_var table)", nm); continue; }
        sp[ns] = a_; sv[ns] = *a_; ns++; *a_ = atoi(eq + 1); if (ok++ < 8) MLOG("DM_NVN_UB: %s = %d (was %d)", nm, atoi(eq + 1), sv[ns - 1]); }
    atomic_store(&g_ub_cur, nc);
}
static int ub_skip(const char *key) {   // Whether this phase should drop draws of this fragment shader
    int uc = atomic_load(&g_ub_cur); if (uc < 0) return 0;
    for (int i = 0; i < g_ub_nk[uc]; i++) { const char *k = g_ub_keys[uc][i]; if (k[0] == '@') continue; if (k[0] == '*' || !strncmp(key, k, strlen(k))) return 1; }
    return 0;
}
static void us_report(uint64_t f); static void ren_report(uint64_t f); static void lay_report(uint64_t f);
void mtl_set_frame(uint64_t f) { atomic_store(&g_cur_frame, f); if (g_ub_n) ub_frame(f); us_report(f); ren_report(f); lay_report(f); }
// GPU timing registration: gpu_tag_begin(frame) before commit, gpu_tag_done(frame, GPU start, GPU end) on completion (seconds on the CACurrentMediaTime base).
// Old-queue command buffers go through gpu_tag_f; the Metal 4 main submission backfills in the feedback of mtl_sub_commit (when switching to Metal 4 all the call sites were lost and the GPU column of the "timing" line became empty)
static void gpu_tag_begin(uint64_t f) {
    unsigned k = f % GRING;
    if (atomic_load(&g_gpu[k].frame) != f) { atomic_store(&g_gpu[k].frame, f); atomic_store(&g_gpu[k].ns, 0); atomic_store(&g_gpu[k].pending, 0); atomic_store(&g_gpu[k].t0, UINT64_MAX); atomic_store(&g_gpu[k].t1, 0); }
    atomic_fetch_add(&g_gpu[k].pending, 1);
}
static void gpu_tag_done(uint64_t f, double g0, double g1) {
    unsigned k = f % GRING;
    if (atomic_load(&g_gpu[k].frame) != f) return;
    double d = g1 - g0;
    if (d > 0) {
        atomic_fetch_add(&g_gpu[k].ns, (uint64_t)(d * 1e9));
        uint64_t s0 = (uint64_t)(g0 * 1e9), s1 = (uint64_t)(g1 * 1e9), v;
        giv_add(f, s0, s1);
        for (v = atomic_load(&g_gpu[k].t0); s0 < v && !atomic_compare_exchange_weak(&g_gpu[k].t0, &v, s0);) {}
        for (v = atomic_load(&g_gpu[k].t1); s1 > v && !atomic_compare_exchange_weak(&g_gpu[k].t1, &v, s1);) {}
    }
    atomic_fetch_sub(&g_gpu[k].pending, 1);
}
static void gpu_tag_f(id<MTLCommandBuffer> cb, uint64_t f) { gpu_tag_begin(f); [cb addCompletedHandler:^(id<MTLCommandBuffer> c) { gpu_tag_done(f, c.GPUStartTime, c.GPUEndTime); }]; }
void gpu_tag(id<MTLCommandBuffer> cb) { gpu_tag_f(cb, atomic_load(&g_cur_frame)); }
double mtl_gpu_ms(uint64_t f) {   // the union of the frame's command-buffer spans; -1 while one is still running or the frame is gone
    unsigned k = f % GRING;
    if (atomic_load(&g_gpu[k].frame) != f || atomic_load(&g_gpu[k].pending)) return -1;
    if (!atomic_load(&g_gpu[k].ns)) return 0;
    unsigned j = f % GIVR; os_unfair_lock_lock(&g_giv[j].lk);
    double ms = g_giv[j].frame == f ? giv_union_ns(g_giv[j].iv, &g_giv[j].n) / 1e6 : -1;
    os_unfair_lock_unlock(&g_giv[j].lk);
    return ms;
}
double mtl_gpu_sum_ms(uint64_t f) {   // the plain sum of the spans (what mtl_gpu_ms reported before 2026-10-19), for comparison with older numbers
    unsigned k = f % GRING;
    if (atomic_load(&g_gpu[k].frame) != f || atomic_load(&g_gpu[k].pending)) return -1;
    return atomic_load(&g_gpu[k].ns) / 1e6;
}
int mtl_gpu_span(uint64_t f, uint64_t *t0, uint64_t *t1) {
    unsigned k = f % GRING;
    if (atomic_load(&g_gpu[k].frame) != f || atomic_load(&g_gpu[k].pending)) return 0;
    *t0 = atomic_load(&g_gpu[k].t0); *t1 = atomic_load(&g_gpu[k].t1);
    return *t1 >= *t0 && *t1;
}
// DM_NVN_GPUWATCH=<first>-<last> (diagnostics): the uniform ranges a submission of those frames binds are copied at its commit and compared byte by
// byte when it completes: data the CPU changed while the GPU still had to read it (how Tears of the Kingdom's dive flicker was found; with uniform
// snapshots on, a changed range the GPU read from its copy is counted apart). Ranges written by the submission's own inline updates are left out,
// and a range also bound as a storage buffer is counted apart (a shader may have written it)
typedef struct { uint64_t addr, size; int stage, index, ssbo, copied; } gw_rng;   // copied: a uniform snapshot of this submission held it when it was bound
static gw_rng *g_gw; static int g_gw_n, g_gw_cap; static uint64_t g_gw_hits, g_gw_checked;
static int gw_on(void) { static long a = -2, b; if (a == -2) { const char *e = getenv("DM_NVN_GPUWATCH"); a = e ? atol(e) : -1; b = e && strchr(e, '-') ? atol(strchr(e, '-') + 1) : a; }
    long f = (long)atomic_load(&g_cur_frame); return a >= 0 && f >= a && f <= b; }
static void gw_note(const p_bind_buf *b, int ssbo) {
    if (!b->addr || !b->size || !gw_on()) return;
    for (int i = g_gw_n - 1; i >= 0 && i >= g_gw_n - 64; i--) if (g_gw[i].addr == b->addr && g_gw[i].size == b->size) return;
    if (g_gw_n == g_gw_cap) { g_gw_cap = g_gw_cap ? g_gw_cap * 2 : 1024; g_gw = realloc(g_gw, (size_t)g_gw_cap * sizeof *g_gw); }
    g_gw[g_gw_n++] = (gw_rng){b->addr, b->size, b->stage, b->index, ssbo, !ssbo && us_find(b->addr, b->size)};
}
static void gw_commit(void) {   // before the commit blocks are copied: copy now, compare on completion
    if (!g_gw_n) return;
    int n = g_gw_n; gw_rng *l = malloc((size_t)n * sizeof *l); memcpy(l, g_gw, (size_t)n * sizeof *l); g_gw_n = 0;
    uint64_t frame = atomic_load(&g_cur_frame);
    {
        uint8_t **snap = calloc((size_t)n, sizeof *snap); int nsnap = 0;
        for (int i = 0; i < n; i++) {
            if (l[i].ssbo || l[i].size > (1u << 20)) continue;
            int upd = g_pend_over; for (int k = 0; k < g_npend && !upd; k++) upd = l[i].addr < g_pend_hi[k] && l[i].addr + l[i].size > g_pend_lo[k];
            if (upd) continue;
            snap[i] = malloc(l[i].size); memcpy(snap[i], (const void *)(uintptr_t)l[i].addr, l[i].size); nsnap++;
        }
        [g_commit_blocks addObject:^{
            int hit = 0, gpu_hit = 0, copied_hit = 0;
            for (int i = 0; i < n; i++) { if (!snap[i]) continue; g_gw_checked++;
                if (memcmp(snap[i], (const void *)(uintptr_t)l[i].addr, l[i].size)) {
                    int gpu = 0; for (int j = 0; j < n && !gpu; j++) gpu = l[j].ssbo && l[i].addr < l[j].addr + l[j].size && l[i].addr + l[i].size > l[j].addr;
                    if (gpu) { gpu_hit++; continue; }   // also bound as a storage buffer in this submission: a shader may have written it
                    if (l[i].copied) { copied_hit++; continue; }   // the GPU read the snapshot taken at the submit call
                    hit++;
                    size_t off = 0; while (off < l[i].size && snap[i][off] == ((const uint8_t *)(uintptr_t)l[i].addr)[off]) off++;
                    if (g_gw_hits++ < 40) MLOG("[gpuwatch] frame %llu: UBO st%d r%d [%#llx, +%llu) changed while this submission was on the GPU (first byte +%zu)", (unsigned long long)frame,
                                              l[i].stage, l[i].index, (unsigned long long)l[i].addr, (unsigned long long)l[i].size, off); }
                free(snap[i]); }
            MLOG("[gpuwatch] frame %llu: %d of %d bound UBO ranges compared byte by byte, %d changed during the GPU work and were read from memory (+%d read from the submit-time copy, +%d also bound as storage buffers)", (unsigned long long)frame, nsnap, n, hit, copied_hit, gpu_hit);
            free(snap); free(l);
        }];
    }
}
// ---------- GPU keep-alive (MacNativeGames, MIT: TOTK_GPU_KEEPALIVE; written anew here) ----------
// Apple GPUs lower their clock when they idle part of each frame: MacNativeGames measured the same compute work at 10.9 ms back to back, 16.8 ms with
// 10 ms gaps, and Tears of the Kingdom's world scene at GPU p50 12.1 → 9.1 ms with a spinner in the gaps. While the game submits, a thread keeps one
// short spin kernel (one threadgroup, ~1 ms, sized from its measured time) on a queue of its own, only while none of the game's command buffers is on
// the GPU (so a game submission waits for at most one), and stops 100 ms after the last submission. Costs power: on by default on the Mac with a
// window only (not headless, not in the tests); DM_NVN_KEEPALIVE=0 / 1 overrides (t_keepalive)
static _Atomic int g_inflight;                   // the game's command buffers committed and not completed
static dispatch_semaphore_t g_ka_idle;           // signalled when g_inflight drops to 0
static _Atomic uint64_t g_last_sub_ns, g_ka_n, g_ka_us;
static _Atomic int g_ka_target_us = 1000;
int mtl_display_hz(void);
static int keepalive_on(void) {   // default: on with a window on the Mac (not in headless runs and the tests)
    static int on = -1;
    if (on < 0) { const char *e = getenv("DM_NVN_KEEPALIVE");
#if TARGET_OS_IPHONE
        on = e ? atoi(e) != 0 : 0;
#else
        on = e ? atoi(e) != 0 : mtl_display_hz() > 0;
#endif
    }
    return on;
}
static void keepalive_start(void) {
    static int started; if (started || !keepalive_on()) return; started = 1;
    NSError *err = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void keep(device float *a [[buffer(0)]], constant uint &n [[buffer(1)]], uint i [[thread_position_in_grid]]) { float x = a[i]; for (uint j = 0; j < n; j++) x = fma(x, 1.0001f, 0.0001f); a[i] = x; }\n" options:nil error:&err];
    id<MTLComputePipelineState> ps = lib ? [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"keep"] error:&err] : nil;
    id<MTLCommandQueue> q = [g_dev newCommandQueue]; id<MTLBuffer> buf = [g_dev newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
    if (!ps || !q || !buf) { MLOG("[red] GPU keep-alive: no spin kernel (%s)", err.localizedDescription.UTF8String); return; }
    g_ka_idle = dispatch_semaphore_create(0);
    MLOG("GPU keep-alive: short spin kernels (~%d us) on a queue of their own while the GPU would idle between the game's work (DM_NVN_KEEPALIVE=0 turns it off)", atomic_load(&g_ka_target_us));
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block uint32_t n = 40000; dispatch_semaphore_t one = dispatch_semaphore_create(1);
        for (;;) @autoreleasepool {
            uint64_t last = atomic_load(&g_last_sub_ns);
            if (!last || clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - last > 100000000ull) { usleep(10000); continue; }   // the game is not rendering
            if (atomic_load(&g_inflight) > 0) { dispatch_semaphore_wait(g_ka_idle, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_MSEC)); continue; }   // its own work keeps the clock up
            dispatch_semaphore_wait(one, DISPATCH_TIME_FOREVER);
            if (atomic_load(&g_inflight) > 0) { dispatch_semaphore_signal(one); continue; }
            uint32_t iters = n;
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:ps]; [ce setBuffer:buf offset:0 atIndex:0]; [ce setBytes:&iters length:4 atIndex:1];
            [ce dispatchThreads:MTLSizeMake(32, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)]; [ce endEncoding];
            [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
                double ms = (c.GPUEndTime - c.GPUStartTime) * 1e3; atomic_fetch_add(&g_ka_n, 1); atomic_fetch_add(&g_ka_us, (uint64_t)(ms * 1e3));
                if (ms > 0.01) { double k = (atomic_load(&g_ka_target_us) * .001) / ms; if (k > 2) k = 2; if (k < 0.5) k = 0.5; double m = n * k; n = m < 2000 ? 2000 : m > 400000 ? 400000 : (uint32_t)m; }
                dispatch_semaphore_signal(one); }];
            [cb commit];
        }
    });
}
static void rp_flush(void);
static const char *cctx_snap(void);   // What is in this submission (printed into the failure line on error; defined before mtl_exec)
// GPU memory budget (MacNativeGames' gpu_budget_check, MIT; written anew here): the four macOS kernel panics it saw all came with the driver out of
// wired memory. Before every commit the GPU allocation is held against DM_NVN_GPU_BUDGET_MB (default 40 % of physical memory on the Mac, off on iOS,
// where the system ends the app first; 0 turns it off): past it the residency census is written and the process stops instead of feeding the driver
static uint64_t gpu_budget_bytes(void) {
    static uint64_t b; static int init;
    if (!init) { init = 1; const char *e = getenv("DM_NVN_GPU_BUDGET_MB");
        if (e) b = strtoull(e, NULL, 10) << 20;
        else if (!TARGET_OS_IPHONE) { uint64_t phys = 0; size_t n = sizeof phys; if (!sysctlbyname("hw.memsize", &phys, &n, NULL, 0)) b = phys / 5 * 2; }
        if (b) MLOG("GPU memory budget %llu MB (DM_NVN_GPU_BUDGET_MB, 0 turns it off)", (unsigned long long)(b >> 20)); }
    return b;
}
static int gpu_budget_exceeded(uint64_t *cur, uint64_t *budget) { *budget = gpu_budget_bytes(); *cur = (uint64_t)g_dev.currentAllocatedSize; return *budget && *cur > *budget; }
static void res_census(unsigned long long frame, unsigned long long rss_mb);
static void gpu_budget_check(void) {
    uint64_t cur, budget; if (!gpu_budget_exceeded(&cur, &budget)) return;
    res_census((unsigned long long)atomic_load(&g_cur_frame), 0);
    MDIE("GPU allocated %llu MB, above the budget of %llu MB: stopping before the driver runs out of wired memory (DM_NVN_GPU_BUDGET_MB)", (unsigned long long)(cur >> 20), (unsigned long long)(budget >> 20));
}
uint64_t mtl_sub_commit(void) {
    gpu_budget_check();
    defer_fallback();   // Deferred merged pass: at the end of the submission there are still P draws not replayed (the normal path never gets here)
    upd_flush(); upd_sub_end();   // renamed uniform updates reach memory at the end of their submission
    rp_flush();
    if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    up_flush();
    uint64_t fence = ++g_fence;
    keepalive_start(); atomic_store(&g_last_sub_ns, clock_gettime_nsec_np(CLOCK_UPTIME_RAW)); atomic_fetch_add(&g_inflight, 1);
    if (g_vis_ring_i >= 0) g_vis_ring[g_vis_ring_i].fence = fence;
    // CPU-visible effects after completion: copy the op table into the callback
    int n = g_npost; post_op *ops = n ? malloc(n * sizeof *ops) : NULL;
    if (n) memcpy(ops, g_post, n * sizeof *ops);
    gw_commit();
    NSArray<dispatch_block_t> *commit_blocks = [g_commit_blocks copy];
#if !DM_NVN_M3
    MTL4CommitOptions *o = [MTL4CommitOptions new];
#endif
    [FB_ON(o, g_cb) FB_SEL:^(FB_ARG f) { (void)f; for (dispatch_block_t block in commit_blocks) block(); }];
    pg_commit(FB_ON(o, g_cb));
    uint64_t gpu_f = atomic_load(&g_cur_frame); gpu_tag_begin(gpu_f);
    NSString *cctx = @(cctx_snap());
    [FB_ON(o, g_cb) FB_SEL:^(FB_ARG cb) {
        gpu_tag_done(gpu_f, cb.GPUStartTime, cb.GPUEndTime);
        if (cb.error) { atomic_store(&g_last_commit_error, 1); static int n, nv; int victim = [cb.error.description containsString:@"InnocentVictim"]; if (victim ? nv++ < 1 : n++ < 8) MLOG("[red] command buffer error details fence=%llu: %s | GPU %.3f→%.3f", (unsigned long long)fence, cb.error.description.UTF8String, cb.GPUStartTime, cb.GPUEndTime); if (!victim) MLOG("[red] context of the failing submit fence=%llu: %s", (unsigned long long)fence, cctx.UTF8String); MLOG("[red] command buffer execution error: %s", cb.error.localizedDescription.UTF8String); }
        for (int i = 0; i < n; i++) {
            if (ops[i].kind == 1) { if (ops[i].mode == 1) *ops[i].val += ops[i].v; else *ops[i].val = ops[i].v; }
            else if (ops[i].kind == 3) {   // Samples passed: the sum of all slots since the reset
                vis_list *l = ops[i].vis; uint64_t sum = l->base;
                for (int k = 0; k < l->n; k++) { sum += ((const uint64_t *)((__bridge id<MTLBuffer>)l->s[k].buf).contents)[l->s[k].slot]; CFRelease(l->s[k].buf); }
                free(l); uint64_t rec[2] = {sum, gpu_ticks()}; memcpy((void *)ops[i].addr, rec, sizeof rec);
            }
            else { uint64_t t = gpu_ticks(); memcpy((uint8_t *)(uintptr_t)ops[i].addr + 8, &t, 8); }   // the timestamp half only: the counter half was written in command order at replay (see OP_REPORT_COUNTER)
        }
        free(ops);
        pthread_mutex_lock(&g_mu); if (fence > g_done) g_done = fence; pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mu);
        if (atomic_fetch_sub(&g_inflight, 1) == 1 && g_ka_idle) dispatch_semaphore_signal(g_ka_idle);
        defer_drain();
    }];
    void arena_commit(uint64_t fence); arena_commit(fence);
    res_commit(); rs_sub_end();   // the encode stage has ended its last pass before the command buffer ends
#if DM_NVN_M3
    [g_cb encodeSignalEvent:g_ev value:fence];
    [g_cb commit];
#else
    [g_cb endCommandBuffer];
    CBUF buffers[] = {g_cb};
    [g_q4 commit:buffers count:1 options:o];
    [g_q4 signalEvent:g_ev value:fence];
#endif
    cb_committed();
    g_us_n = 0;   // the uniform copies belong to this submission
    g_alloc_fence[g_alloc_cur] = fence;
    g_cb = nil;
    g_commit_blocks = nil;
    objc_autoreleasePoolPop(g_sub_pool); g_sub_pool = NULL;
    return fence;
}

uint64_t mtl_done_fence(void) { pthread_mutex_lock(&g_mu); uint64_t d = g_done; pthread_mutex_unlock(&g_mu); return d; }   // highest completed submission fence
uint64_t mtl_last_fence(void) { return g_fence; }
int mtl_last_commit_error(void) { return atomic_load(&g_last_commit_error); }

int mtl_wait(uint64_t fence, uint64_t timeout_ns) { @autoreleasepool {
    struct timespec dl; clock_gettime(CLOCK_REALTIME, &dl);
    uint64_t ns = (uint64_t)dl.tv_nsec + (timeout_ns > 3600000000000ull ? 3600000000000ull : timeout_ns);
    dl.tv_sec += ns / 1000000000ull; dl.tv_nsec = ns % 1000000000ull;
    pthread_mutex_lock(&g_mu);
    int r = 0;
    while (g_done < fence) if ((r = pthread_cond_timedwait(&g_cv, &g_mu, &dl))) break;
    int ok = g_done >= fence;
    pthread_mutex_unlock(&g_mu);
    return ok;
} }

static void mtl_finish_gpu(void) {
    if (g_fence) mtl_wait(g_fence, UINT64_MAX);
    up_wait_zero(&g_up_pending);
}
void mtl_present_flush(void);
// nvnQueueFinish waits for the GPU work submitted so far, not for queued presents to be shown: with a window the display link takes one present per
// tick, so each call cost a display frame or two (seedds/nxnative 3b72aea, MIT: Fire Emblem: Three Houses calls it after every resource upload, its
// first load took 78 s on an iPhone). A swapchain texture is still handed back only after its previous present (AcquireTexture); mtl_drain flushes
void mtl_finish(void) { @autoreleasepool { mtl_finish_gpu(); } }
static void present_drop_for_suspend(void);
void mtl_drain(void) { @autoreleasepool { present_drop_for_suspend(); mtl_present_flush(); mtl_init(); id<MTLCommandBuffer> cb = q_cb(); [cb commit]; [cb waitUntilCompleted]; mtl_finish_gpu(); } }

// ================= Render replay =================
#include "../../host/front.h"
static int g_red_once[104];
#define RED_ONCE(k, ...) do { if (!g_red_once[k]++) MLOG("[red] " __VA_ARGS__); } while (0)

// ---------- Texture → MTLTexture ----------
static int fmt_compressed(int f) { return (f >= 0x41 && f <= 0x50) || (f >= 0x79 && f <= 0x94); }
static int fmt_depth(int f) { return f >= 0x31 && f <= 0x36; }
typedef struct { MTLPixelFormat a, b; } pfv_pair;
static const pfv_pair g_pfv_srgb[] = {
    {MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm_sRGB},
    {MTLPixelFormatBGRA8Unorm, MTLPixelFormatBGRA8Unorm_sRGB},
    {MTLPixelFormatBC1_RGBA, MTLPixelFormatBC1_RGBA_sRGB},
    {MTLPixelFormatBC2_RGBA, MTLPixelFormatBC2_RGBA_sRGB},
    {MTLPixelFormatBC3_RGBA, MTLPixelFormatBC3_RGBA_sRGB},
    {MTLPixelFormatBC7_RGBAUnorm, MTLPixelFormatBC7_RGBAUnorm_sRGB},
};
static int tex_need_pfv(MTLPixelFormat base, MTLPixelFormat view) {
    if (base == view) return 0;
    for (size_t i = 0; i < sizeof g_pfv_srgb / sizeof *g_pfv_srgb; i++)
        if ((base == g_pfv_srgb[i].a && view == g_pfv_srgb[i].b) || (base == g_pfv_srgb[i].b && view == g_pfv_srgb[i].a)) return 0;
    return 1;
}
// Cache tables on the replay hot path always use nvn_hmap (C hash, keys not boxed); the table stores CFBridgingRetain'ed objects, CFRelease'd on replace / delete
static void hm_rel(void *v) { CFRelease(v); }
static __unsafe_unretained id hm_get_id(const nvn_hmap *m, const void *k) { return (__bridge id)nvn_hm_get(m, k); }
static void hm_put_id(nvn_hmap *m, const void *k, id o) { void *old = nvn_hm_put(m, k, (void *)CFBridgingRetain(o)); if (old) CFRelease(old); }
static void hm_del_id(nvn_hmap *m, const void *k) { void *old = nvn_hm_del(m, k); if (old) CFRelease(old); }
static nvn_hmap g_by_serial = {.klen = 8};     // Serial → MTLTexture / NvPkg / NvProg
static pthread_mutex_t g_smu = PTHREAD_MUTEX_INITIALIZER;
// Serial table generation: +1 when entries are added / removed or a packaged texture is replaced. Downstream caches (texture views, programs) record the generation at fetch time; if it is unchanged they can be used directly without another table lookup
static _Atomic uint64_t g_ser_gen = 1;
// Which serial each generation step was for (g_ser_chg[gen % SER_CHG_N]; 0 = every serial): a texture ID's view whose serial is not among the steps
// since it was checked stays valid (ser_unaffected). Every release (fin_drain, 30 a submission in Tears of the Kingdom) and every re-upload stepped
// the generation, and every texture ID went down the slow path after each (MacNativeGames g_ser_chg, MIT; written anew here). Steps happen under g_smu
#define SER_CHG_N 1024
static _Atomic uint64_t g_ser_chg[SER_CHG_N];
static void ser_bump_locked(uint64_t serial) {
    uint64_t g = atomic_load_explicit(&g_ser_gen, memory_order_relaxed) + 1;
    atomic_store_explicit(&g_ser_chg[g % SER_CHG_N], serial, memory_order_relaxed);
    atomic_store_explicit(&g_ser_gen, g, memory_order_release);   // the step's serial is visible before the step
}
static void ser_bump(uint64_t serial) { pthread_mutex_lock(&g_smu); ser_bump_locked(serial); pthread_mutex_unlock(&g_smu); }
static int ser_unaffected(uint64_t from, uint64_t to, uint64_t serial) {   // 1: none of the steps (from, to] was for serial or for every serial
    if (!serial || to - from >= SER_CHG_N) return 0;
    for (uint64_t g = from + 1; g <= to; g++) { uint64_t s = atomic_load_explicit(&g_ser_chg[g % SER_CHG_N], memory_order_relaxed); if (!s || s == serial) return 0; }
    return atomic_load_explicit(&g_ser_gen, memory_order_acquire) - from < SER_CHG_N;   // no step read here was overwritten meanwhile
}
// ---------- GPU textures sharing one storage (MacNativeGames' stor_*, MIT; written anew here) ----------
// Several live texture objects can describe the same GPU-only memory with the same layout and format: on the console what is rendered through one is
// what the others sample. Every serial had its own MTLTexture, so the others read their own, stale contents (Tears of the Kingdom, 2026-10-19: a
// 564x81 R8 texture and 25x25 pairs in a CPU_NO_ACCESS pool, sampled 139 times after the other object was rendered into). Textures that are not
// CPU-filled are now keyed by (storage, layout, format): one MTLTexture for all of them. The table holds its own reference, so a serial leaving lets go
// of its reference only (defer_obj_unref, the texture stays resident for the others); an entry nobody holds is kept STOR_IDLE submissions (objects
// re-initialized at the same storage every frame take it back) and then retired. DM_NVN_TEX_SHARE=0: one texture per serial
typedef struct { uint64_t mem, size; uint32_t w, h, d, levels, target, samples, fmt, pad; } stor_key;   // 48 bytes, no padding left uninitialized
typedef struct { stor_key k; void *tex; uint64_t *ser; int nser, cap; uint64_t idle_fence; } stor_ent;   // tex: CFBridgingRetain'd
static nvn_hmap g_stor = {.klen = sizeof(stor_key)}, g_stor_obj = {.klen = 8};   // key → entry; texture → entry (under g_smu)
static stor_ent **g_stor_list; static int g_nstor, g_stor_cap;
static uint64_t g_stor_shared, g_stor_entries, g_stor_swept, g_stor_usage_miss;
enum { STOR_IDLE = 600 };
static int stor_on(void) { static int v = -1; if (v < 0) { const char *e = getenv("DM_NVN_TEX_SHARE"); v = !(e && !strcmp(e, "0")); if (!v) MLOG("DM_NVN_TEX_SHARE=0: one texture per serial"); } return v; }
static int stor_drop_holder_locked(id o, uint64_t ser) {   // 1: o belongs to the table (the caller only unrefs it)
    uint64_t ok = (uint64_t)(uintptr_t)(__bridge void *)o; stor_ent *e = nvn_hm_get(&g_stor_obj, &ok); if (!e) return 0;
    for (int i = 0; i < e->nser; i++) if (e->ser[i] == ser) { e->ser[i] = e->ser[--e->nser]; break; }
    if (!e->nser) e->idle_fence = g_fence;
    return 1;
}
static void stor_add_holder_locked(id o, uint64_t ser) {
    uint64_t ok = (uint64_t)(uintptr_t)(__bridge void *)o; stor_ent *e = nvn_hm_get(&g_stor_obj, &ok); if (!e) return;
    for (int i = 0; i < e->nser; i++) if (e->ser[i] == ser) return;
    if (e->nser == e->cap) { e->cap = e->cap ? e->cap * 2 : 4; e->ser = realloc(e->ser, (size_t)e->cap * sizeof *e->ser); if (!e->ser) MDIE("storage holder list"); }
    e->ser[e->nser++] = ser;
}
static __unsafe_unretained id serial_get(uint64_t k) { pthread_mutex_lock(&g_smu); __unsafe_unretained id o = hm_get_id(&g_by_serial, &k); pthread_mutex_unlock(&g_smu); return o; }
static void serial_put(uint64_t k, id o) { pthread_mutex_lock(&g_smu); id old = hm_get_id(&g_by_serial, &k); if (old) { if (stor_drop_holder_locked(old, k)) defer_obj_unref(old); else defer_obj_release(old); }
    hm_put_id(&g_by_serial, &k, o); stor_add_holder_locked(o, k); ser_bump_locked(k); pthread_mutex_unlock(&g_smu); }
static void serial_del(uint64_t k) { pthread_mutex_lock(&g_smu); id old = hm_get_id(&g_by_serial, &k); if (old) { if (stor_drop_holder_locked(old, k)) defer_obj_unref(old); else defer_obj_release(old); }
    hm_del_id(&g_by_serial, &k); ser_bump_locked(k); pthread_mutex_unlock(&g_smu); }
static void stor_sweep(void) {   // fin_drain: entries nobody has held for STOR_IDLE submissions are retired
    pthread_mutex_lock(&g_smu);
    for (int i = 0; i < g_nstor;) { stor_ent *e = g_stor_list[i];
        if (e->nser || e->idle_fence + STOR_IDLE > g_fence) { i++; continue; }
        uint64_t ok = (uint64_t)(uintptr_t)e->tex; nvn_hm_del(&g_stor_obj, &ok); nvn_hm_del(&g_stor, &e->k);
        defer_obj_release(CFBridgingRelease(e->tex)); free(e->ser); free(e); g_stor_list[i] = g_stor_list[--g_nstor]; g_stor_swept++; }
    pthread_mutex_unlock(&g_smu);
}
// Host record of a packaged texture: the current MTLTexture, the upload stamp, and the global write generation at the last check
@interface NvPkg : NSObject { @public id<MTLTexture> tex, spare; uint64_t stamp, seen, hash, csub, chash, spare_fence; int tracked, hashed, dspan; } @end   // hash: full hash of the uploaded content under DM_NVN_DIRTYCHECK
// csub: the submission that last checked it (tex_mtl); tracked: its storage was tracked at that check; hashed / chash: a small texture checked by its content (pkg_hashed);
// dspan: the slot of the dirty-tracking range holding its storage (nvn_dirty_state_hint, -1 until found); spare: the texture before the last re-upload,
// written by the next one once spare_fence (the last submission that could read it) has completed
@implementation NvPkg
- (void)dealloc { res_remove(tex); res_remove(spare); }
@end
static uint64_t g_pkg_uploads, g_pkg_reuploads, g_pkg_miss, g_pkg_spare_reuse, g_pkg_spare_drop;   // re-uploads written into the spare; spares dropped unused
// DM_NVN_COUNTS (plan item 56, measuring what dropping cold CPU-filled textures could free): every 300 submissions, on the submit thread, the bytes of
// the uploaded textures by how many submissions ago they were last used (csub): [0] 0-30, [1] 31-300, [2] 301-1800, [3] more; [4] how many
static NSHashTable *g_pkgs; static uint64_t g_pkg_age[5];
static void pkg_census(void) {
    uint64_t a[5] = {0};
    for (NvPkg *pk in g_pkgs) { if (!pk->tex) continue; uint64_t age = g_sub_serial - pk->csub, b = (uint64_t)pk->tex.allocatedSize + (pk->spare ? (uint64_t)pk->spare.allocatedSize : 0);
        a[age <= 30 ? 0 : age <= 300 ? 1 : age <= 1800 ? 2 : 3] += b; a[4]++; }
    memcpy(g_pkg_age, a, sizeof a);
}
void mtl_pkg_age(uint64_t out[5]) { memcpy(out, g_pkg_age, sizeof g_pkg_age); }
enum { PKG_SPARE_KEEP = 120 };   // submissions a spare is kept without a re-upload (a texture re-uploaded once would otherwise hold two)
static uint64_t g_pfv_upgrades;
// DM_NVN_DIRTYCHECK=1 (diagnostic, compared against ground truth): fully hash the pool content on every use; changed but not detected by dirty-page tracking = a missed detection
static int dirtycheck(void) { static int v = -1; if (v < 0) v = getenv("DM_NVN_DIRTYCHECK") != NULL; return v; }
static uint64_t full_hash(const uint8_t *m, uint64_t n) { uint64_t h = 1469598103934665603ull; for (uint64_t i = 0; i < n; i++) h = (h ^ m[i]) * 1099511628211ull; return h; }
// The GPU does not support BC compressed formats (A15 / A16 etc.): BC textures are created in the decompressed format and decompressed on the CPU at upload / buffer→texture copy time (nvn_bcdec.c).
// BC3 among the game textures was converted to ASTC offline by the Legacy Device Pack (tools/astc_pack.py); what reaches here is the small remainder of BC. The test switch DM_TEST_NO_BC=1 forces this path on any machine
static int no_bc(void) {
    static int v = -1;
    if (v < 0) { const char *e = getenv("DM_TEST_NO_BC"); v = (e && *e && strcmp(e, "0")) || ![g_dev supportsBCTextureCompression];
        if (v) MLOG("GPU does not support BC compressed formats%s: BC textures are created in decompressed formats (BC1–5 decompressed on the GPU, BC6H / BC7 / 3D on the CPU)", e && *e && strcmp(e, "0") ? " (test switch DM_TEST_NO_BC)" : ""); }
    return v;
}
static int bc_unpack(uint32_t nvn_fmt, uint32_t *pf, int *bpp) { return no_bc() && nvn_bc_unpacked(nvn_fmt, pf, bpp); }
static MTLTextureDescriptor *tex_desc(const tex_t *t, int packaged) {
    uint32_t pf = 0; uint8_t swz[4];
    if (!nvn_fmt_to_mtl(t->d.format, &pf, swz) || !pf) { RED_ONCE(0, "texture format %#x has no Metal equivalent (first case)", t->d.format); return nil; }
    // Over Metal's size limits: newTextureWithDescriptor would abort the process (failed assertion in MTLTextureDescriptor validation),
    // so the texture is not created and reads as unbound. Logged with every field (first 16) to find where such a description comes from.
    const char *bad = nvn_texdesc_metal_check(&t->d);
    if (bad) {
        static _Atomic int n;
        if (atomic_fetch_add(&n, 1) < 16)
            MLOG("[red] texture not created (%s): ser %llu magic %#x target %d format %#x flags %#x samples %d size %ux%ux%u levels %u layout %d mem %p",
                 bad, t->serial, t->magic, t->d.target, t->d.format, t->d.flags, t->d.samples, t->d.width, t->d.height, t->d.depth, t->d.levels,
                 t->has_layout, (void *)t->mem);
        return nil;
    }
    int unp = 0; { uint32_t upf; int ubpp; if (bc_unpack(t->d.format, &upf, &ubpp)) { pf = upf; unp = 1; } }
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.pixelFormat = (MTLPixelFormat)pf;
    d.width = t->d.width ? t->d.width : 1; d.height = t->d.height ? t->d.height : 1; d.depth = 1; d.arrayLength = 1;
    d.mipmapLevelCount = t->d.levels ? t->d.levels : 1;
    switch (t->d.target) {
        // 1D / 1D array are created as one-row 2D / 2D array textures (nxnative 42a50ef): translated shaders never declare texture1d (none in manosaba's
        // library) and sample them as 2D, and a Metal 1D texture bound to a texture2d argument is a type mismatch with undefined reads. On Maxwell a 2D
        // sample of a 1D texture reads its one row
        case 0: d.textureType = MTLTextureType2D; d.height = 1; break;
        case 2: d.textureType = MTLTextureType3D; d.depth = t->d.depth; break;
        case 3: d.textureType = MTLTextureType2DArray; d.arrayLength = t->d.height; d.height = 1; break;
        case 4: d.textureType = MTLTextureType2DArray; d.arrayLength = t->d.depth; break;
        case 5: d.textureType = MTLTextureType2DMultisample; d.sampleCount = t->d.samples; d.mipmapLevelCount = 1; break;
        case 6: d.textureType = MTLTextureType2DMultisampleArray; d.sampleCount = t->d.samples; d.arrayLength = t->d.depth; d.mipmapLevelCount = 1; break;
        case 8: d.textureType = MTLTextureTypeCube; break;
        case 9: d.textureType = MTLTextureTypeCubeArray; d.arrayLength = t->d.depth; break;
        case 10: RED_ONCE(1, "buffer texture (TARGET_BUFFER) not implemented"); return nil;
        default: d.textureType = MTLTextureType2D; break;
    }
    d.storageMode = MTLStorageModePrivate;   // Render targets and assets both go in GPU private storage (lossless compression available)
    d.usage = MTLTextureUsageShaderRead | (fmt_compressed(t->d.format) || packaged ? 0 : MTLTextureUsageRenderTarget)
            | (t->d.flags & NVN_TEXTURE_FLAGS_IMAGE ? MTLTextureUsageShaderWrite : 0)   // Image usage: shader-writable (compute kernels generating the 3D color lookup table, etc.)
            | (unp ? MTLTextureUsageShaderWrite | MTLTextureUsagePixelFormatView : 0);   // No BC: textures in the decompressed format are written by the GPU decompression kernel (up_dec) / receive whole-block copies from ASTC sources (copy_t2t_astc)
    return d;
}
// In-place upgrade: when the original texture was not created with PixelFormatView (off by default, to keep Apple GPU lossless compression) but a different-format view is needed, create a new one with the original spec + PixelFormatView, copy over every slice × level, and replace the registration.
// Count: across the 4 screens character select / camp / wilderness / combat, 17473 textures needed a different-format view 0 times, so this is a fallback and does not rely on predicting which textures need it
static id<MTLTexture> tex_upgrade_pfv(const tex_t *t, id<MTLTexture> base, MTLPixelFormat view_pf) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = base.textureType; d.pixelFormat = base.pixelFormat; d.width = base.width; d.height = base.height; d.depth = base.depth;   // Keep the original format, only add the format-view usage
    d.arrayLength = base.arrayLength; d.mipmapLevelCount = base.mipmapLevelCount; d.sampleCount = base.sampleCount;
    d.storageMode = base.storageMode; d.cpuCacheMode = base.cpuCacheMode; d.hazardTrackingMode = base.hazardTrackingMode;
    d.resourceOptions = base.resourceOptions; d.usage = base.usage | MTLTextureUsagePixelFormatView;
    id<MTLTexture> upgraded = [g_dev newTextureWithDescriptor:d];
    if (!upgraded) { RED_ONCE(45, "texture upgrade failed ser=%llu format %lu → %lu", t->serial, (unsigned long)base.pixelFormat, (unsigned long)view_pf); return base; }
    res_add(upgraded);
    BENC b = blit();
    NSUInteger slices = base.textureType == MTLTextureType3D ? 1 : base.arrayLength * (base.textureType == MTLTextureTypeCube || base.textureType == MTLTextureTypeCubeArray ? 6 : 1);
    for (NSUInteger l = 0; l < base.mipmapLevelCount; l++) {
        NSUInteger w = MAX(base.width >> l, 1u), h = MAX(base.height >> l, 1u), z = base.textureType == MTLTextureType3D ? MAX(base.depth >> l, 1u) : 1;
        if (base.textureType == MTLTextureType3D)
            enc_b_copy_texture(b, base, 0, l, MTLOriginMake(0, 0, 0), MTLSizeMake(w, h, z), upgraded, 0, l, MTLOriginMake(0, 0, 0));
        else for (NSUInteger s = 0; s < slices; s++)
            enc_b_copy_texture(b, base, s, l, MTLOriginMake(0, 0, 0), MTLSizeMake(w, h, 1), upgraded, s, l, MTLOriginMake(0, 0, 0));
    }
    id holder = serial_get(t->serial);
    if ([holder isKindOfClass:[NvPkg class]]) { id<MTLTexture> old = ((NvPkg *)holder)->tex; ((NvPkg *)holder)->tex = upgraded; defer_obj_release(old); ser_bump(t->serial); }
    else serial_put(t->serial, upgraded);
    MLOG("texture upgraded for format-changing views ser=%llu base format %lu → view format %lu (upgrades=%llu)", t->serial, (unsigned long)base.pixelFormat, (unsigned long)view_pf, ++g_pfv_upgrades);
    return upgraded;
}
// Packaged texture upload: first set read-only, then take the stamp, then read the pool memory and deswizzle into a staging buffer, and blit into a new private texture.
// Batching: uploads within one replay submission share one upload command buffer (compute encoder deswizzle + a unified blit), flushed before the replay command buffer is committed;
// the same queue executes in commit order ⇒ uploads are always finished before the first sample. Uploads outside a submission are flushed on the spot. The staging area is cut from 32 MB private blocks, held by the command buffer until completion.
static _Atomic uint64_t g_upload_ns;   // Cumulative time of deswizzle + upload encoding on the submit thread (timing instrumentation)
static _Atomic uint64_t g_upload_gpu_ns;
static CBUF g_up_cb;
static CENC g_up_ce;
static _Atomic int g_up_alloc_busy[3];
static unsigned g_up_seq;
#define UP_BLOCK_SIZE (32u * 1024u * 1024u)
typedef struct {
    __unsafe_unretained id<MTLBuffer> src;
    size_t off, row, image;
    MTLSize size;
    __unsafe_unretained id<MTLTexture> dst;   // Strongly referenced by g_up_texs until the flush is encoded
    NSUInteger slice, level;
} up_blit;
static up_blit *g_up_blits; static int g_nup_blits, g_up_blitcap;
// Without BC, BC1–5 are decompressed on the GPU (A16 logs: CPU deswizzle + CPU decompression took over 300 ms in a single frame): the GPU deswizzle writes the compressed blocks into the staging area, and at flush time, after the barrier,
// the compute kernel bcd decodes them into the texture one thread per block (the target is a 2D view in the decompressed format; an sRGB base texture is written with raw values through an RGBA8Unorm view). BC6H / BC7 / 3D textures are very few and still go through the CPU (nvn_bcdec.c)
typedef struct { __unsafe_unretained id<MTLBuffer> src, params; size_t off, poff; uint32_t bw, bh; __unsafe_unretained id<MTLTexture> view; } up_dec;   // view: held by g_up_texs within the batch, and afterwards by defer_obj_unref until the GPU finishes
static up_dec *g_up_decs; static int g_nup_decs, g_up_deccap;
static const char k_bcd_msl[] =
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct P { uint off, pitch, w, h, fmt; };\n"   // fmt: 1 BC1, 2 BC2, 3 BC3, 4 BC4, 5 BC4 signed, 6 BC5, 7 BC5 signed
"static float3 c565(uint c) { return float3((c >> 11) & 31, (c >> 5) & 63, c & 31) / float3(31, 63, 31); }\n"
"static void col(device const uchar *b, thread float4 *o, bool four) {\n"
"  uint c0 = b[0] | (b[1] << 8), c1 = b[2] | (b[3] << 8), ix = b[4] | (b[5] << 8) | (b[6] << 16) | (b[7] << 24); float3 e0 = c565(c0), e1 = c565(c1); float4 p[4];\n"
"  p[0] = float4(e0, 1); p[1] = float4(e1, 1);\n"
"  if (four || c0 > c1) { p[2] = float4((2 * e0 + e1) / 3, 1); p[3] = float4((e0 + 2 * e1) / 3, 1); } else { p[2] = float4((e0 + e1) / 2, 1); p[3] = float4(0); }\n"
"  for (int i = 0; i < 16; i++) o[i] = p[(ix >> (2 * i)) & 3]; }\n"
"static void a8(device const uchar *b, thread float *o, bool sn) {\n"   // Single-channel block of BC4 / BC3 alpha / BC5
"  float a0 = sn ? max(float(as_type<char>(b[0])), -127.0) / 127 : b[0] / 255.0, a1 = sn ? max(float(as_type<char>(b[1])), -127.0) / 127 : b[1] / 255.0;\n"
"  bool eight = sn ? as_type<char>(b[0]) > as_type<char>(b[1]) : b[0] > b[1]; float lo = sn ? -1 : 0; float p[8]; p[0] = a0; p[1] = a1;\n"
"  for (int k = 2; k < 8; k++) p[k] = eight ? ((8 - k) * a0 + (k - 1) * a1) / 7 : (k < 6 ? ((6 - k) * a0 + (k - 1) * a1) / 5 : (k == 6 ? lo : 1));\n"
"  uint lo24 = b[2] | (b[3] << 8) | (b[4] << 16), hi24 = b[5] | (b[6] << 8) | (b[7] << 16);\n"
"  for (int i = 0; i < 16; i++) o[i] = p[i < 8 ? (lo24 >> (3 * i)) & 7 : (hi24 >> (3 * (i - 8))) & 7]; }\n"
"kernel void bcd(device const uchar *src [[buffer(0)]], device const P &p [[buffer(1)]], texture2d<float, access::write> dst [[texture(0)]], uint2 g [[thread_position_in_grid]]) {\n"
"  uint nbx = (p.w + 3) / 4, nby = (p.h + 3) / 4; if (g.x >= nbx || g.y >= nby) return;\n"
"  uint bb = (p.fmt == 1 || p.fmt == 4 || p.fmt == 5) ? 8 : 16; device const uchar *b = src + p.off + g.y * p.pitch + g.x * bb; float4 o[16]; float a[16], c[16];\n"
"  if (p.fmt == 1) col(b, o, false);\n"
"  else if (p.fmt == 2) { col(b + 8, o, true); for (int i = 0; i < 16; i++) o[i].a = ((b[i / 2] >> (4 * (i & 1))) & 15) / 15.0; }\n"
"  else if (p.fmt == 3) { col(b + 8, o, true); a8(b, a, false); for (int i = 0; i < 16; i++) o[i].a = a[i]; }\n"
"  else if (p.fmt == 4 || p.fmt == 5) { a8(b, a, p.fmt == 5); for (int i = 0; i < 16; i++) o[i] = float4(a[i], 0, 0, 1); }\n"
"  else { a8(b, a, p.fmt == 7); a8(b + 8, c, p.fmt == 7); for (int i = 0; i < 16; i++) o[i] = float4(a[i], c[i], 0, 1); }\n"
"  for (int i = 0; i < 16; i++) { uint2 q = g * 4 + uint2(i & 3, i >> 2); if (q.x < p.w && q.y < p.h) dst.write(o[i], q); } }\n";
static int bcd_fmt(uint32_t f) {   // NVN format → bcd fmt; 0 = not decoded on the GPU (BC6H / BC7 / non-BC)
    switch (f) { case 0x41: case 0x42: case 0x45: case 0x46: return 1; case 0x43: case 0x47: return 2; case 0x44: case 0x48: return 3;
                 case 0x49: return 4; case 0x4a: return 5; case 0x4b: return 6; case 0x4c: return 7; default: return 0; }
}
static id<MTLComputePipelineState> bcd_pso(void) {
    static id<MTLComputePipelineState> ps; static int failed;
    if (!ps && !failed) { NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(k_bcd_msl) options:nil error:&e]; id<MTLFunction> fn = lib ? [lib newFunctionWithName:@"bcd"] : nil;
        ps = fn ? [g_dev newComputePipelineStateWithFunction:fn error:&e] : nil;
        if (!ps) { failed = 1; MLOG("[red] no BC: cannot create the GPU decompression pipeline %s (falling back to CPU decompression)", e.localizedDescription.UTF8String); } else MLOG("no BC: BC1–5 now decompressed on the GPU"); }
    return ps;
}
static NSMutableArray *g_up_texs;   // Target textures in the batch: before the flush, textures may be replaced / released within the same submission
static id<MTLBuffer> g_up_block;
static size_t g_up_block_off, g_up_block_size;
static NSMutableArray *g_up_keep;
// Pooled staging blocks (MacNativeGames, MIT): a fresh 32 MiB private block per upload batch, added to and later removed from the residency set, made
// every batch flush commit the residency set (Tears of the Kingdom: 2091 blocks in about 4000 frames). Up to UP_POOL blocks are made once and stay
// resident; a block is free again when the batch that used it has completed on the GPU. Larger requests, or every block in flight, use a one-off
// block retired as before (t_uppool)
#if TARGET_OS_IPHONE
#define UP_POOL 2   // about 4 GB per app in total
#else
#define UP_POOL 6
#endif
static __strong id<MTLBuffer> g_up_pool[UP_POOL]; static _Atomic int g_up_pool_busy[UP_POOL]; static int g_up_pool_n, g_up_block_pooled; static uint32_t g_up_batch_mask; static uint64_t g_up_pool_hits, g_up_pool_misses;
static int up_pool_take(void) {   // a free pooled block (made and made resident once), or -1
    for (int i = 0; i < g_up_pool_n; i++) if (!(g_up_batch_mask >> i & 1) && !atomic_load(&g_up_pool_busy[i])) { atomic_store(&g_up_pool_busy[i], 1); g_up_batch_mask |= 1u << i; g_up_pool_hits++; return i; }
    if (g_up_pool_n < UP_POOL) { id<MTLBuffer> b = [g_dev newBufferWithLength:UP_BLOCK_SIZE options:MTLResourceStorageModePrivate]; if (b) { int i = g_up_pool_n++; g_up_pool[i] = b; res_add(b); atomic_store(&g_up_pool_busy[i], 1); g_up_batch_mask |= 1u << i; return i; } }
    g_up_pool_misses++; return -1;
}


// The upload command buffer was discarded by the system (dropped along during GPU error recovery; the first frame on entering Travincal drops one every run): the objects of this batch of textures are built and the timestamps updated, but the content was never written in,
// and if the pool memory on the game side no longer changes it will never be re-uploaded. Record this batch of target textures, and the next time any of them is fetched treat it as dirty and re-upload once.
// DM_TEST_UP_LOST=<batch index> (for testing): treat that batch of uploads as dropped, to verify the re-upload path.
static NSHashTable *g_up_lost; static os_unfair_lock g_up_lost_lk = OS_UNFAIR_LOCK_INIT; static _Atomic int g_up_lost_n; static _Atomic uint64_t g_up_lost_redo;   // Weak-reference table: if a texture in the record is never fetched again and is released normally, this table does not keep it alive
static int up_lost_take(id tex) {   // This texture's upload was dropped: take it out of the record and return 1
    if (!tex) return 0; os_unfair_lock_lock(&g_up_lost_lk); int hit = [g_up_lost containsObject:tex]; if (hit) { [g_up_lost removeObject:tex]; atomic_store(&g_up_lost_n, (int)g_up_lost.allObjects.count); atomic_fetch_add(&g_up_lost_redo, 1); } os_unfair_lock_unlock(&g_up_lost_lk); return hit;
}
static void up_diag(void);
static void up_flush(void) {
    up_owner_check("up_flush");
    if (!g_up_cb) return;
    if (g_up_ce) {
        m4_end(g_up_ce); g_up_ce = nil;
    }
#if DM_NVN_M3
    // Older API: copy and compute are two kinds of encoder - first a copy encoder does "staging block -> texture", then a compute encoder does the GPU decompression for devices without BC
    BENC b = g_nup_blits ? [g_up_cb blitCommandEncoder] : nil;
    for (int i = 0; b && i < g_nup_blits; i++) {
        up_blit *x = &g_up_blits[i];
        enc_b_copy_buffer_texture(b, x->src, x->off, x->row, x->image, x->size, x->dst, x->slice, x->level, MTLOriginMake(0, 0, 0));
    }
    [b endEncoding];
    CENC dc = g_nup_decs ? [g_up_cb computeCommandEncoder] : nil;
    if (dc) {
        [dc setComputePipelineState:bcd_pso()];
        for (int i = 0; i < g_nup_decs; i++) { up_dec *x = &g_up_decs[i];
            [dc setBuffer:x->src offset:0 atIndex:0]; [dc setBuffer:x->params offset:x->poff atIndex:1]; [dc setTexture:x->view atIndex:0];
            [dc dispatchThreadgroups:MTLSizeMake((x->bw + 7) / 8, (x->bh + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)]; }
    }
    [dc endEncoding]; g_up_ce = nil;
#else
    CENC b = g_nup_blits || g_nup_decs ? g_up_ce = [g_up_cb computeCommandEncoder] : nil;
    if (b) [b barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    for (int i = 0; b && i < g_nup_blits; i++) {
        up_blit *x = &g_up_blits[i];
        enc_b_copy_buffer_texture(b, x->src, x->off, x->row, x->image, x->size, x->dst, x->slice, x->level, MTLOriginMake(0, 0, 0));
    }
    if (b && g_nup_decs) {   // GPU decompression without BC (see up_dec): offsets in the parameter block are relative to the start of the staging block
        [b setArgumentTable:g_up_ct]; [b setComputePipelineState:bcd_pso()];
        for (int i = 0; i < g_nup_decs; i++) { up_dec *x = &g_up_decs[i];
            [g_up_ct setAddress:x->src.gpuAddress atIndex:0]; [g_up_ct setAddress:x->params.gpuAddress + x->poff atIndex:1]; [g_up_ct setTexture:x->view.gpuResourceID atIndex:0];
            [b dispatchThreadgroups:MTLSizeMake((x->bw + 7) / 8, (x->bh + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)]; }
    }
    if (b) { m4_end(b); g_up_ce = nil; }
#endif
    CBUF cb = g_up_cb;
    unsigned slot = (g_up_seq - 1) % 3;
    NSMutableArray *dsts = [NSMutableArray arrayWithCapacity:(NSUInteger)g_nup_blits]; for (int i = 0; i < g_nup_blits; i++) if (g_up_blits[i].dst) [dsts addObject:g_up_blits[i].dst];
    static int lost_at = -2; static uint64_t batch_n; if (lost_at == -2) { const char *e = getenv("DM_TEST_UP_LOST"); lost_at = e ? atoi(e) : -1; } int fake_lost = dsts.count && lost_at > 0 && (int)++batch_n == lost_at;
#if !DM_NVN_M3
    MTL4CommitOptions *o = [MTL4CommitOptions new];
#endif
    atomic_fetch_add(&g_up_pending, 1);
    uint32_t pool_mask = g_up_batch_mask;
    [FB_ON(o, cb) FB_SEL:^(FB_ARG f) {
        if (f.error) MLOG("[red] upload command buffer execution error: %s", f.error.description.UTF8String);
        if (f.error || fake_lost) {
            os_unfair_lock_lock(&g_up_lost_lk); if (!g_up_lost) g_up_lost = [NSHashTable weakObjectsHashTable]; for (id d in dsts) [g_up_lost addObject:d]; int n = (int)g_up_lost.allObjects.count; atomic_store(&g_up_lost_n, n); os_unfair_lock_unlock(&g_up_lost_lk);
            ser_bump(0);   // Make the view cache of every texture ID take the slow path once (on a cache hit tex_mtl is not passed through and this record is not seen)
            MLOG("%supload command buffer lost: the %lu textures of this batch are marked as unwritten and re-uploaded on next use (%d pending re-upload in total)", fake_lost ? "DM_TEST_UP_LOST: " : "", (unsigned long)dsts.count, n);
        }
        double d = f.GPUEndTime - f.GPUStartTime;
        if (d > 0) atomic_fetch_add(&g_upload_gpu_ns, (uint64_t)(d * 1e9));
        atomic_store(&g_up_alloc_busy[slot], 0);
        for (int i = 0; i < UP_POOL; i++) if (pool_mask >> i & 1) atomic_store(&g_up_pool_busy[i], 0);   // pooled staging blocks of this batch are free again
        atomic_fetch_sub(&g_up_pending, 1);
        up_notify();
    }];
    res_commit();
#if DM_NVN_M3
    [cb commit];
#else
    [cb endCommandBuffer];
    CBUF buffers[] = {cb};
    [g_q4 commit:buffers count:1 options:o];
#endif
    cb_committed();
    g_up_cb = nil; if (g_up_block && !g_up_block_pooled) defer_obj_release(g_up_block); g_up_block = nil; g_up_block_pooled = 0; g_up_block_off = g_up_block_size = 0; g_up_batch_mask = 0;
    for (id obj in g_up_keep) defer_obj_release(obj);
    [g_up_keep removeAllObjects];
    up_diag();
    g_nup_blits = 0; g_nup_decs = 0;
    [g_up_texs removeAllObjects];
}

static void up_begin(void) {
    up_owner_check("up_begin");
    if (g_up_cb) return;
    unsigned slot = g_up_seq++ % 3;
    up_wait_zero(&g_up_alloc_busy[slot]);
    atomic_store(&g_up_alloc_busy[slot], 1);
#if DM_NVN_M3
    g_up_cb = [g_q commandBuffer];
    g_up_ce = [g_up_cb computeCommandEncoder];
#else
    [g_up_alloc4[slot] reset];
    g_up_cb = [g_dev newCommandBuffer];
    [g_up_cb beginCommandBufferWithAllocator:g_up_alloc4[slot]];
    g_up_ce = [g_up_cb computeCommandEncoder];
    [g_up_ce barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [g_up_ce setArgumentTable:g_up_ct];
#endif
    if (!g_up_texs) g_up_texs = [NSMutableArray array];
    if (!g_up_keep) g_up_keep = [NSMutableArray array];
}

// Diagnostic readout (low frequency; printed only when the block switch count changed and ≥ 1 second since the last line, at most 200 lines per game): how many times an upload batch ran out of staging block and switched blocks midway; GPU allocated, residency set object count, deferred-release queue length.
// If the old block is not retired on a switch it stays in the residency set and can never be freed, and "GPU allocated" climbs one block at a time with the switch count
static uint64_t g_up_blocks_new, g_up_swaps, g_up_swap_bytes; static NSHashTable *g_up_old;   // g_up_old: old blocks switched out (weak references); the diagnostic line counts how many are still alive
static void up_diag(void) {
    // Print a line when the block switch count changes; then one more line 5 seconds later (that batch's commit is long done and deferred retirement drained, so "GPU allocated" is the settled number)
    static uint64_t said_swaps = ~0ull, last_ns; static int lines, follow; uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    int chg = g_up_swaps != said_swaps, fol = follow && now - last_ns >= 5000000000ull; if ((!chg && !fol) || lines >= 200) return;
    if (chg && last_ns && now - last_ns < 1000000000ull) return; last_ns = now; said_swaps = g_up_swaps; lines++; follow = chg;
    unsigned long alive = 0, inres = 0; uint64_t abytes = 0; NSArray *olds = g_up_old.allObjects;
    pthread_mutex_lock(&g_res_mu); unsigned long nres = (unsigned long)g_res_objects.allObjects.count; for (id<MTLBuffer> o in olds) { alive++; abytes += o.length; inres += [g_res_objects containsObject:o]; } pthread_mutex_unlock(&g_res_mu);
    pthread_mutex_lock(&g_deferred_mu); unsigned long ndef = (unsigned long)g_deferred.count; pthread_mutex_unlock(&g_deferred_mu);
    MLOG("upload staging blocks%s: %llu created in total, %llu block switches within a batch (swapped-out old blocks %llu MB in total); swapped-out old blocks still alive now: %lu blocks %llu MB, still in the residency set: %lu blocks; GPU allocated %llu MB, residency set %lu objects, deferred-release queue %lu", fol && !chg ? " (after settling)" : "",
         (unsigned long long)g_up_blocks_new, (unsigned long long)g_up_swaps, (unsigned long long)(g_up_swap_bytes >> 20), alive, (unsigned long long)(abytes >> 20), inres, (unsigned long long)(g_dev.currentAllocatedSize >> 20), nres, ndef);
}
static id<MTLBuffer> up_alloc(size_t n, size_t *off) {
    size_t need = (n + 255u) & ~((size_t)255u);
    if (!g_up_block || g_up_block_off + need > g_up_block_size) {
        // Block switch: the old block is still referenced by copy / decompress commands already recorded in this batch and cannot be freed on the spot; hand it to g_up_keep, to be retired later with the other staging after the flush commits (removed from the residency set on retire).
        // Previously g_up_block was simply replaced with the new block here: nobody retired the old block, yet it stayed in the residency set, so each extra block switch in an upload batch leaked one block (usually 32 MB) of GPU memory.
        // The old block and the "current block" retired at flush are two objects, so nothing is retired twice
        if (g_up_block && g_up_block_pooled) { g_up_swaps++; g_up_block = nil; }   // a pooled block is freed with its batch (up_flush), not retired
        g_up_blocks_new++; if (g_up_block) { g_up_swaps++; g_up_swap_bytes += g_up_block_size; if (!g_up_old) g_up_old = [NSHashTable weakObjectsHashTable]; [g_up_old addObject:g_up_block]; static int leak = -1; if (leak < 0) leak = getenv("DM_TEST_UP_LEAK") != NULL;   // test switch DM_TEST_UP_LEAK=1: do not retire the old block, as before the fix (for comparison, to measure the leak)
            if (!leak) { if (!g_up_keep) g_up_keep = [NSMutableArray array]; [g_up_keep addObject:g_up_block]; } }
        int pi = need <= UP_BLOCK_SIZE ? up_pool_take() : -1;
        g_up_block_pooled = pi >= 0;
        if (pi >= 0) { g_up_block = g_up_pool[pi]; g_up_block_size = UP_BLOCK_SIZE; g_up_blocks_new--; }
        else {
            g_up_block_size = n > UP_BLOCK_SIZE ? need : UP_BLOCK_SIZE;
            g_up_block = [g_dev newBufferWithLength:g_up_block_size options:MTLResourceStorageModePrivate];
            if (!g_up_block) MDIE("failed to create the upload staging block for swizzled textures %#zx", g_up_block_size);
            res_add(g_up_block);
        }
        g_up_block_off = 0;
    }
    *off = g_up_block_off;
    g_up_block_off += need;
    return g_up_block;
}

// Deswizzle parameter blocks: 64 bytes per cell, cut sequentially from a 64 KB shared-storage block; a full block is replaced by a new one, and the old block is released lazily by fence
static id<MTLBuffer> g_up_pblock; static size_t g_up_pblock_off;
static id<MTLBuffer> up_param_alloc(size_t *off) {
    if (!g_up_pblock || g_up_pblock_off + 64 > g_up_pblock.length) {
        if (g_up_pblock) defer_obj_release(g_up_pblock);
        g_up_pblock = [g_dev newBufferWithLength:64 << 10 options:MTLResourceStorageModeShared];
        if (!g_up_pblock) MDIE("failed to create the deswizzle parameter block");
        res_add(g_up_pblock); g_up_pblock_off = 0;
    }
    *off = g_up_pblock_off; g_up_pblock_off += 64;
    return g_up_pblock;
}
static void up_blit_add(id<MTLBuffer> src, size_t off, size_t row, size_t image, MTLSize size,
                        id<MTLTexture> dst, NSUInteger slice, NSUInteger level) {
    if (g_nup_blits == g_up_blitcap) {
        g_up_blitcap = g_up_blitcap ? g_up_blitcap * 2 : 256;
        g_up_blits = realloc(g_up_blits, g_up_blitcap * sizeof *g_up_blits);
    }
    g_up_blits[g_nup_blits++] = (up_blit){src, off, row, image, size, dst, slice, level};
}

// Small CPU-filled textures (up to PKG_HASH_MAX bytes) are checked by a content hash once per submission instead of write-protecting their pages
// (MacNativeGames pkg_hashed, MIT; written anew here). Tears of the Kingdom rewrites a few 4x4 textures on the CPU every frame: each write was a page
// fault on a game thread and a step of the guest-write generation, after which every argument block was encoded again and every CPU-filled texture
// bound later was looked up again; their 16 KB host pages also hold other data, whose writes made them dirty without a change. DM_NVN_PKG_HASH=0: protected as the others
#define PKG_HASH_MAX (4u << 10)
static int check_once(void) {   // DM_NVN_CHECK_ONCE=0: a CPU-filled texture is checked at every use, as before
    static int v = -1; if (v < 0) { const char *e = getenv("DM_NVN_CHECK_ONCE"); v = !(e && !strcmp(e, "0")); if (!v) MLOG("DM_NVN_CHECK_ONCE=0: CPU-filled textures checked at every use"); }
    return v;
}
static int pkg_hashed(const tex_t *t) {
    static int on = -1; if (on < 0) { const char *e = getenv("DM_NVN_PKG_HASH"); on = !e || atoi(e); }
    return on && t->mem && t->size && t->size <= PKG_HASH_MAX;
}
static uint64_t pkg_hash(const void *p, uint64_t n) {   // four independent lanes over 8-byte words, then the tail bytes
    const uint8_t *b = p; uint64_t a[4] = {0x9E3779B97F4A7C15ull ^ n, 0xC2B2AE3D27D4EB4Full, 0x165667B19E3779F9ull, 0x27D4EB2F165667C5ull}, i = 0;
    for (; i + 32 <= n; i += 32) for (int k = 0; k < 4; k++) { uint64_t w; memcpy(&w, b + i + 8 * k, 8); a[k] = (a[k] ^ w) * 0xff51afd7ed558ccdull; a[k] ^= a[k] >> 29; }
    uint64_t h = a[0] ^ (a[1] * 3) ^ (a[2] * 5) ^ (a[3] * 7);
    for (; i < n; i++) h = (h ^ b[i]) * 0x100000001b3ull;
    h ^= h >> 33; h *= 0xc4ceb9fe1a85ec53ull; return h ^ (h >> 33);
}
static id<MTLTexture> pkg_upload_(const tex_t *t, uint64_t *stamp, id<MTLTexture> reuse);
static id<MTLTexture> pkg_upload(const tex_t *t, uint64_t *stamp, id<MTLTexture> reuse) {   // reuse: a texture of this tex_t no GPU work reads any more, written instead of a new one
    struct timespec a, b; clock_gettime(CLOCK_MONOTONIC, &a);
    id<MTLTexture> r = pkg_upload_(t, stamp, reuse);
    clock_gettime(CLOCK_MONOTONIC, &b); uint64_t d_ = (uint64_t)((b.tv_sec - a.tv_sec) * 1000000000ll + b.tv_nsec - a.tv_nsec);
    atomic_fetch_add(&g_upload_ns, d_); g_up_total_ns += d_;
    return r;
}
uint64_t mtl_upload_ns_take(void) { return atomic_exchange(&g_upload_ns, 0); }
uint64_t mtl_upload_gpu_ns_take(void) { return atomic_exchange(&g_upload_gpu_ns, 0); }
void mtl_create_stats(uint64_t *lib, uint64_t *pso) { *lib = g_bp_lib_n; *pso = g_bp_pso_n; }
void mtl_create_ns(uint64_t *lib_ns, uint64_t *pso_ns) { *lib_ns = g_bp_lib_ns; *pso_ns = g_bp_pso_ns; }   // Cumulative time spent synchronously creating shader libraries / pipelines on the spot (the long-frame log takes the per-frame difference)
uint64_t mtl_upload_bytes(void) { return g_bp_up_bytes; }   // Cumulative texture upload bytes
static id<MTLTexture> pkg_upload_(const tex_t *t, uint64_t *stamp, id<MTLTexture> reuse) {
    MTLTextureDescriptor *d = tex_desc(t, t->has_layout);   // a CPU-filled texture without a packaged layout may become a render target later (see tex_gpu_write)
    if (!d) return nil;
    int same = reuse && reuse.width == d.width && reuse.height == d.height && reuse.depth == d.depth && reuse.pixelFormat == d.pixelFormat && reuse.textureType == d.textureType &&
               reuse.mipmapLevelCount == d.mipmapLevelCount && reuse.arrayLength == d.arrayLength && reuse.usage == d.usage;
    id<MTLTexture> mt = same ? reuse : [g_dev newTextureWithDescriptor:d];
    if (!mt) { RED_ONCE(2, "failed to create MTLTexture %ux%u format %#x target %d", t->d.width, t->d.height, t->d.format, t->d.target); return nil; }
    res_add(mt);   // Both first upload and re-upload register residency here (Metal 4 does not make resources resident automatically; a missed registration = GPU address page fault)
    if (!pkg_hashed(t)) nvn_dirty_protect(t->mem, t->size);
    *stamp = nvn_dirty_now();
    int bw, bh, bpb = nvn_fmt_bpb(t->d.format, &bw, &bh);
    unsigned layers = (t->d.target == 4 || t->d.target == 9) ? t->d.depth : t->d.target == 8 ? 6 : t->d.target == 3 ? t->d.height : 1;
    if (t->d.target == 9) layers *= 6;
    uint32_t upf; int ubpp = 0, unp = bc_unpack(t->d.format, &upf, &ubpp);   // No BC: decompress on the CPU after deswizzling, with the staging area sized for the decompressed data
    size_t total = 0;
    for (unsigned l = 0; l < d.mipmapLevelCount; l++) {
        uint32_t w = MAX(t->d.width >> l, 1u), h = MAX(t->d.height >> l, 1u), z = t->d.target == 2 ? MAX(t->d.depth >> l, 1u) : 1;
        total += unp ? (size_t)w * ubpp * h * z * layers : (size_t)((w + bw - 1) / bw) * bpb * ((h + bh - 1) / bh) * z * layers;
    }
    g_bp_up_bytes += total;
    void *mb; uint64_t mo;
    int gdec = unp && t->d.target != 2 && bcd_fmt(t->d.format) && bcd_pso();   // BC1–5 without BC: GPU deswizzle + GPU decompression
    size_t ctotal = 0;   // Staging size of the compressed blocks (with GPU decompression the staging area holds compressed blocks)
    if (gdec) for (unsigned l = 0; l < d.mipmapLevelCount; l++) { uint32_t w = MAX(t->d.width >> l, 1u), h = MAX(t->d.height >> l, 1u); ctotal += (size_t)((w + bw - 1) / bw) * bpb * ((h + bh - 1) / bh) * layers; }
    int use_gpu = (!unp || gdec) && g_nvn_deswz_gpu && mtl_addr((uint64_t)t->mem, t->size, &mb, &mo);
    if (g_nvn_deswz_gpu && !use_gpu && !unp) RED_ONCE(40, "swizzled texture storage is not in a memory pool, falling back to the CPU");
    if (use_gpu) {
        // The GPU reads the memory pool at execution time, which is closer to a real Switch than a snapshot at CPU upload time; the dirty-page stamp is still taken before encoding, and later writes still trigger a re-upload.
        up_begin();
        size_t stg_off;
        id<MTLBuffer> stg = up_alloc(gdec ? ctotal : total ? total : 16, &stg_off);
        size_t off = 0; int enc_ok = g_up_ce != nil, nb0 = g_nup_blits, nd0 = g_nup_decs;
        for (unsigned l = 0; enc_ok && l < d.mipmapLevelCount; l++) {
            uint32_t w = MAX(t->d.width >> l, 1u), h = MAX(t->d.height >> l, 1u), z = t->d.target == 2 ? MAX(t->d.depth >> l, 1u) : 1;
            size_t pitch = (size_t)((w + bw - 1) / bw) * bpb, rows = (h + bh - 1) / bh;
            for (unsigned y = 0; y < layers; y++) {
#if DM_NVN_M3
                if (nvn_deswz_gpu_encode(g_up_ce, (__bridge id<MTLBuffer>)mb, mo, &t->d, l, y, stg, stg_off + off, pitch)) { enc_ok = 0; break; }
#else
                size_t poff; id<MTLBuffer> params = up_param_alloc(&poff);   // Metal 4 has no setBytes: the parameter block of each deswizzle is cut from a shared block (no new GPU buffer each time)
                if (nvn_deswz_gpu_encode_m4(g_up_ce, g_up_ct, params, poff, (__bridge id<MTLBuffer>)mb, mo, &t->d, l, y, stg, stg_off + off, pitch)) { enc_ok = 0; break; }
#endif
                if (gdec) {   // Decompression job: dispatched at flush time after the barrier (see up_flush)
                    MTLPixelFormat vf = mt.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB ? MTLPixelFormatRGBA8Unorm : mt.pixelFormat;
                    id<MTLTexture> v = [mt newTextureViewWithPixelFormat:vf textureType:MTLTextureType2D levels:NSMakeRange(l, 1) slices:NSMakeRange(y, 1)];
                    size_t qoff; id<MTLBuffer> q = up_param_alloc(&qoff);
                    if (!v || !q) { enc_ok = 0; break; }
                    uint32_t *pp = (uint32_t *)((uint8_t *)q.contents + qoff); pp[0] = (uint32_t)(stg_off + off); pp[1] = (uint32_t)pitch; pp[2] = w; pp[3] = h; pp[4] = (uint32_t)bcd_fmt(t->d.format);
                    if (g_nup_decs == g_up_deccap) { g_up_deccap = g_up_deccap ? g_up_deccap * 2 : 256; g_up_decs = realloc(g_up_decs, g_up_deccap * sizeof *g_up_decs); }
                    g_up_decs[g_nup_decs++] = (up_dec){stg, q, 0, qoff, (w + 3) / 4, (h + 3) / 4, v}; [g_up_texs addObject:v]; defer_obj_unref(v);   // View: released after this submission finishes running, residency not revoked (what is resident is the base texture)
                } else
                up_blit_add(stg, stg_off + off, pitch, pitch * rows, MTLSizeMake(w, h, z), mt, y, l);
                off += pitch * rows * z;
            }
        }
        if (enc_ok) {
            [g_up_texs addObject:mt];
            if (!g_cb) up_flush();
            return mt;
        }
        g_nup_blits = nb0; g_nup_decs = nd0;   // Roll back the copies / decompressions already recorded for this texture: the already-encoded deswizzle only writes the staging area and is harmless; this texture takes the CPU path below instead
        if (!g_cb) up_flush();
        RED_ONCE(41, "swizzled texture: GPU deswizzle does not support format %#x target %d, falling back to the CPU", t->d.format, t->d.target);
    }

    up_begin();
    id<MTLBuffer> stg = [g_dev newBufferWithLength:total ? total : 16 options:MTLResourceStorageModeShared];
    res_add(stg); [g_up_keep addObject:stg];
    size_t off = 0;
    for (unsigned l = 0; l < d.mipmapLevelCount; l++) {
        uint32_t w = MAX(t->d.width >> l, 1u), h = MAX(t->d.height >> l, 1u), z = t->d.target == 2 ? MAX(t->d.depth >> l, 1u) : 1;
        size_t pitch = (size_t)((w + bw - 1) / bw) * bpb, rows = (h + bh - 1) / bh;
        for (unsigned y = 0; y < layers; y++) {
            if (unp) {   // No BC: first deswizzle into a temporary area (compressed blocks), then decompress layer by layer into the staging area
                uint8_t *cb = malloc(pitch * rows * z); size_t up = (size_t)w * ubpp;
                if (!cb || nvn_deswizzle(&t->d, l, y, t->mem, cb, pitch)) { free(cb); RED_ONCE(9, "deswizzle failed format %#x target %d", t->d.format, t->d.target); break; }
                for (uint32_t zi = 0; zi < z; zi++) nvn_bc_decode(t->d.format, cb + zi * pitch * rows, pitch, w, h, (uint8_t *)stg.contents + off + zi * up * h, up);
                free(cb);
                up_blit_add(stg, off, up, up * h, MTLSizeMake(w, h, z), mt, y, l);
                off += up * h * z;
                continue;
            }
            if (nvn_deswizzle(&t->d, l, y, t->mem, (uint8_t *)stg.contents + off, pitch)) { RED_ONCE(9, "deswizzle failed format %#x target %d", t->d.format, t->d.target); break; }
            up_blit_add(stg, off, pitch, pitch * rows, MTLSizeMake(w, h, z), mt, y, l);
            off += pitch * rows * z;
        }
    }
    up_flush();
    return mt;
}
// ---------- CPU-filled textures without a packaged layout ----------
// A texture's content is its storage: on the Switch the CPU and the GPU both write that memory. The host keeps a Metal copy, so it has to know who wrote
// last. Textures with a packaged layout were always uploaded from the pool (and re-uploaded when its pages change); every other texture was GPU-only and
// started as zeros. Tears of the Kingdom gives no packaged layout to its assets (26 SetPackagedTextureLayout calls against 757 registered textures): it
// writes the block-linear data into CPU-cached pools and flushes the range (8536 FlushMappedRange calls at startup), so the title mural's albedo and
// every other asset sampled as black. Now, as in LASRecomp (Peiikai, MIT: a texture is uploaded from guest memory when sampled until it is rendered
// into), a texture in a CPU-visible pool, not compressible, and not yet written by the GPU is uploaded from its storage once the CPU has filled it:
// non-zero storage at first use (the host never writes texture storage and a fresh pool reads as zero), or written pages later (it is watched). Such
// an upload is created render-target capable; when the GPU first writes the texture (render target, copy or clear destination, image store) that
// MTLTexture becomes the GPU's own and is no longer re-uploaded.
static pthread_mutex_t g_cpuf_mu = PTHREAD_MUTEX_INITIALIZER;
static CFMutableSetRef g_gpu_owned;          // serials the GPU has written
static CFMutableDictionaryRef g_cpuf_watch;  // candidates still GPU-only (storage empty at first use) → dirty stamp + 1
static int tex_cpu_candidate(const tex_t *t) {   // linear textures are made on the pool buffer instead (tex_linear)
    return t->mem && t->pool && !(t->pool->flags & NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS) && !(t->d.flags & (NVN_TEXTURE_FLAGS_COMPRESSIBLE | NVN_TEXTURE_FLAGS_LINEAR | NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET))
        && t->d.target != 10 && !t->has_layout;
}
// A linear texture in a CPU-visible pool is made on the pool's MTLBuffer, so what the CPU writes is what the GPU reads, with no upload: games rasterize
// glyphs on the CPU into one (nxnative found it in Mario's 2048x8192 R8 glyph cache, flags IMAGE | LINEAR: menus without text; tex_linear in its
// nvn_mtl.m, seedds, MIT). Tears of the Kingdom's is IMAGE | LINEAR in a CPU_UNCACHED pool; as a private texture its menu text never showed.
static id<MTLTexture> tex_linear(const tex_t *t) {
    if (!(t->d.flags & (NVN_TEXTURE_FLAGS_LINEAR | NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET)) || !t->mem || !t->pool || (t->pool->flags & NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS)) return nil;
    if (t->d.target != NVN_TEXTURE_TARGET_2D || t->d.levels > 1 || t->d.samples > 1) return nil;
    uint32_t pf = 0; uint8_t swz[4]; int bw, bh, bpb = nvn_fmt_bpb(t->d.format, &bw, &bh);
    if (!nvn_fmt_to_mtl(t->d.format, &pf, swz) || !pf || !bpb || bw != 1 || bh != 1) return nil;
    size_t row = t->d.stride ? t->d.stride : (size_t)t->d.width * bpb;
    void *mb; uint64_t mo;
    if (!mtl_addr((uint64_t)t->mem, (uint64_t)row * (t->d.height ? t->d.height : 1), &mb, &mo)) { RED_ONCE(81, "linear texture storage is not in a memory pool (%ux%u format %#x)", t->d.width, t->d.height, t->d.format); return nil; }
    id<MTLBuffer> b = (__bridge id<MTLBuffer>)mb;
    NSUInteger al = [g_dev minimumLinearTextureAlignmentForPixelFormat:(MTLPixelFormat)pf];
    if (mo % al || row % al) { RED_ONCE(82, "linear texture offset %#llx / row pitch %zu not %lu-byte aligned: made as a private texture (CPU writes not seen)", (unsigned long long)mo, row, (unsigned long)al); return nil; }
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)pf width:t->d.width ? t->d.width : 1 height:t->d.height ? t->d.height : 1 mipmapped:NO];
    d.resourceOptions = b.resourceOptions;
    d.usage = MTLTextureUsageShaderRead | (t->d.flags & NVN_TEXTURE_FLAGS_IMAGE ? MTLTextureUsageShaderWrite : 0) | (t->d.flags & NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET ? MTLTextureUsageRenderTarget : 0);
    return [b newTextureWithDescriptor:d offset:mo bytesPerRow:row];
}
static int gpu_owned(uint64_t ser) {
    pthread_mutex_lock(&g_cpuf_mu); int r = g_gpu_owned && CFSetContainsValue(g_gpu_owned, (const void *)(uintptr_t)ser); pthread_mutex_unlock(&g_cpuf_mu);
    return r;
}
static int storage_filled(const tex_t *t) {
    const uint64_t *w = (const uint64_t *)(const void *)t->mem; size_t nw = (size_t)t->size / 8;
    for (size_t i = 0; i < nw; i++) if (w[i]) return 1;
    return 0;
}
static void cpuf_watch(const tex_t *t) {   // submit thread: protect the storage, so a later CPU write shows as dirty pages
    nvn_dirty_protect(t->mem, t->size);
    uint64_t st = nvn_dirty_now();
    pthread_mutex_lock(&g_cpuf_mu);
    if (!g_cpuf_watch) g_cpuf_watch = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    CFDictionarySetValue(g_cpuf_watch, (const void *)(uintptr_t)t->serial, (const void *)(uintptr_t)(st + 1));
    pthread_mutex_unlock(&g_cpuf_mu);
}
static int cpuf_written(const tex_t *t) {   // a watched candidate whose storage the CPU has written since: leaves the watch list
    pthread_mutex_lock(&g_cpuf_mu);
    uintptr_t v = g_cpuf_watch ? (uintptr_t)CFDictionaryGetValue(g_cpuf_watch, (const void *)(uintptr_t)t->serial) : 0;
    int w = v && nvn_dirty_since(t->mem, t->size, (uint64_t)v - 1);
    if (w) CFDictionaryRemoveValue(g_cpuf_watch, (const void *)(uintptr_t)t->serial);
    pthread_mutex_unlock(&g_cpuf_mu);
    return w;
}
// The pool memory is this texture's content (ReadTexels / WriteTexels go through it): packaged, or a candidate the GPU has not written that is not GPU-only yet
static int tex_membacked(const tex_t *t) {
    if (!t->mem) return 0;
    if (t->has_layout) return 1;
    if (!tex_cpu_candidate(t) || gpu_owned(t->serial)) return 0;
    __unsafe_unretained id have = serial_get(t->serial);
    return !have || [have isKindOfClass:[NvPkg class]];
}
// ---------- GPU results written back when the CPU invalidates a pool (MacNativeGames' wb_note / mtl_pool_invalidate, MIT; written anew here) ----------
// On the console the GPU writes a texture's storage, and the game reads it with the CPU after nvnMemoryPoolInvalidateMappedRange (CPU-cached pools).
// Here a CPU-filled texture the GPU then writes keeps the result only in its MTLTexture, and the CPU read what it had uploaded before: Tears of the
// Kingdom bakes terrain tile normals on the GPU and copies them with the CPU into new tiles (MacNativeGames: after travelling, the ground turned black
// block by block). Each GPU write of such a texture is noted (storage protected, a reference kept until its serial is released); an invalidate over
// its storage waits for the GPU and writes every level and layer back in the NVN layout, unless the CPU wrote that memory since (its bytes are newer)
// or a later rendering of the same memory supersedes it (t_wb)
typedef struct { tex_t t; uint64_t stamp; void *obj; } wb_ent;
static nvn_hmap g_wb = {.klen = 8}; static pthread_mutex_t g_wb_mu = PTHREAD_MUTEX_INITIALIZER; static uint64_t g_wb_done, g_wb_skip_cpu, g_wb_bytes;
static void wb_free(wb_ent *e) { if (!e) return; if (e->obj) { defer_obj_unref((__bridge id)e->obj); CFRelease(e->obj); } free(e); }
static id<MTLTexture> tex_mtl(const tex_t *ct);
static void wb_note(const tex_t *t) {   // submit thread: the GPU writes t in this submission (every caller makes its MTLTexture right after)
    if (!t->mem || !t->size) return;
    id o = serial_get(t->serial); if (!o) { tex_mtl(t); o = serial_get(t->serial); } if (!o) return;
    nvn_dirty_protect(t->mem, t->size);   // CPU writes after this rendering show in nvn_dirty_since
    uint64_t stamp = nvn_dirty_now(), k = t->serial;
    pthread_mutex_lock(&g_wb_mu);
    wb_ent *e = nvn_hm_get(&g_wb, &k);
    if (e) { e->stamp = stamp; e->t = *t; }
    else if (g_wb.n < 8192) { e = calloc(1, sizeof *e); if (!e) MDIE("write-back record"); e->t = *t; e->stamp = stamp; e->obj = (void *)CFBridgingRetain(o); nvn_hm_put(&g_wb, &k, e); }
    else RED_ONCE(87, "GPU write-back table full (8192 textures): texture %llu is not written back on an invalidate", (unsigned long long)t->serial);
    pthread_mutex_unlock(&g_wb_mu);
}
static void wb_released(uint64_t serial) { pthread_mutex_lock(&g_wb_mu); wb_ent *e = nvn_hm_del(&g_wb, &serial); pthread_mutex_unlock(&g_wb_mu); wb_free(e); }   // fin_drain
static int wb_level(const tex_t *t, id<MTLTexture> mt, unsigned level, unsigned layer) {
    int bw, bh, bpb = nvn_fmt_bpb(t->d.format, &bw, &bh);
    uint32_t lw = MAX(t->d.width >> level, 1u), lh = MAX(t->d.height >> level, 1u);
    size_t lp = (size_t)((lw + bw - 1) / bw) * bpb, lr = (lh + bh - 1) / bh;
    id<MTLBuffer> buf = [g_dev newBufferWithLength:lp * lr options:MTLResourceStorageModeShared]; if (!buf) return 0;
    id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> b = enc_b_begin(cb);
    [b copyFromTexture:mt sourceSlice:layer sourceLevel:level sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(lw, lh, 1) toBuffer:buf destinationOffset:0 destinationBytesPerRow:lp destinationBytesPerImage:lp * lr];
    enc_b_end(b); [cb commit]; [cb waitUntilCompleted];
    if (cb.status == MTLCommandBufferStatusError || nvn_swizzle(&t->d, level, layer, buf.contents, lp, t->mem)) return 0;
    g_wb_bytes += lp * lr; return 1;
}
void mtl_pool_invalidate(const pool_t *p, uint64_t off, uint64_t n) { @autoreleasepool {   // hle_nvn.c nvnMemoryPoolInvalidateMappedRange (game thread)
    if (!p || !p->mem || !n) return;
    const uint8_t *a = p->mem + off, *z = a + n;
    wb_ent *list[512]; int nl = 0;
    pthread_mutex_lock(&g_wb_mu);
    for (int again = 1; again && nl < 512;) { again = 0;   // a deletion shifts entries: scan again
        for (uint32_t i = 0; i < g_wb.cap && nl < 512; i++) { wb_ent *e = g_wb.vals ? g_wb.vals[i] : NULL;
            if (!e || e->t.mem >= z || e->t.mem + e->t.size <= a) continue;
            uint64_t k = e->t.serial; nvn_hm_del(&g_wb, &k); list[nl++] = e; again = 1; break; } }
    pthread_mutex_unlock(&g_wb_mu);
    if (!nl) return;
    mtl_finish_gpu();
    int fresh[512];   // decided for all before anything is written (a write-back writes the pages); of several renderings of one memory only the newest
    for (int i = 0; i < nl; i++) fresh[i] = !nvn_dirty_since(list[i]->t.mem, list[i]->t.size, list[i]->stamp);
    for (int i = 0; i < nl; i++) for (int j = 0; j < nl; j++) if (i != j && fresh[i] == 1 && fresh[j] && list[j]->t.mem == list[i]->t.mem && list[j]->stamp > list[i]->stamp) { fresh[i] = 2; break; }
    for (int i = 0; i < nl; i++) {
        wb_ent *e = list[i]; const tex_t *t = &e->t; id o = (__bridge id)e->obj; id<MTLTexture> mt = [o isKindOfClass:[NvPkg class]] ? ((NvPkg *)o)->tex : o; uint32_t upf; int ubpp;
        if (fresh[i] != 1) { if (!fresh[i]) g_wb_skip_cpu++; wb_free(e); continue; }
        if (!mt || bc_unpack(t->d.format, &upf, &ubpp) || t->d.target == 2 || t->d.samples > 1) { RED_ONCE(88, "GPU write-back: texture format %#x target %d not supported (first case)", t->d.format, t->d.target); wb_free(e); continue; }
        dm_guest_write_prepare(t->mem, t->size);
        unsigned layers = t->d.target == NVN_TEXTURE_TARGET_2D || !t->layer_size ? 1 : t->size / t->layer_size, ok = 1;
        for (unsigned l = 0; l < (t->d.levels ? t->d.levels : 1) && ok; l++) for (unsigned y = 0; y < layers && ok; y++) ok = wb_level(t, mt, l, y);
        uint64_t d = ++g_wb_done;
        if (!ok) RED_ONCE(89, "GPU write-back of texture %llu (format %#x) failed (first case)", (unsigned long long)t->serial, t->d.format);
        else if (d <= 4 || !(d % 1000)) MLOG("GPU write-back on invalidate: texture %llu %ux%u format %#x (%llu so far, %.1f MB; %llu skipped, the CPU had written them since)", (unsigned long long)t->serial,
                                            t->d.width, t->d.height, t->d.format, (unsigned long long)d, g_wb_bytes / 1048576.0, (unsigned long long)g_wb_skip_cpu);
        wb_free(e);
    }
} }
// The GPU is about to write this texture: from now on its MTLTexture is the content. An upload of a CPU-filled texture carries on as that texture
static void tex_gpu_write(const tex_t *t) {
    if (!t || !t->serial || !tex_cpu_candidate(t)) return;
    pthread_mutex_lock(&g_cpuf_mu);
    if (!g_gpu_owned) g_gpu_owned = CFSetCreateMutable(NULL, 0, NULL);
    int had = CFSetContainsValue(g_gpu_owned, (const void *)(uintptr_t)t->serial);
    if (!had) { CFSetAddValue(g_gpu_owned, (const void *)(uintptr_t)t->serial); if (g_cpuf_watch) CFDictionaryRemoveValue(g_cpuf_watch, (const void *)(uintptr_t)t->serial); }
    pthread_mutex_unlock(&g_cpuf_mu);
    if (!had) {
        id have = serial_get(t->serial);
        if ([have isKindOfClass:[NvPkg class]]) { id<MTLTexture> tx = ((NvPkg *)have)->tex; ((NvPkg *)have)->tex = nil; if (tx) serial_put(t->serial, tx); }   // NvPkg's dealloc would take tx out of residency
    }
    wb_note(t);
}
void tex_forget_serial(uint64_t ser) {   // the texture object was finalized: its serial is never used again
    pthread_mutex_lock(&g_cpuf_mu);
    if (g_gpu_owned) CFSetRemoveValue(g_gpu_owned, (const void *)(uintptr_t)ser);
    if (g_cpuf_watch) CFDictionaryRemoveValue(g_cpuf_watch, (const void *)(uintptr_t)ser);
    pthread_mutex_unlock(&g_cpuf_mu);
}
static int stor_key_of(const tex_t *t, stor_key *k) {   // a GPU-only texture (not CPU-filled, not on a pool buffer) that can share by storage
    if (!stor_on() || !t->mem || !t->size || t->has_layout || tex_cpu_candidate(t) || t->d.target == NVN_TEXTURE_TARGET_BUFFER || (t->d.flags & (NVN_TEXTURE_FLAGS_LINEAR | NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET))) return 0;
    memset(k, 0, sizeof *k);
    k->mem = (uint64_t)(uintptr_t)t->mem; k->size = t->size; k->w = t->d.width; k->h = t->d.height; k->d = t->d.depth; k->levels = t->d.levels; k->target = (uint32_t)t->d.target;
    k->samples = t->d.samples; k->fmt = (uint32_t)t->d.format;
    return 1;
}
static id<MTLTexture> tex_mtl(const tex_t *ct) {
    tex_t *t = (tex_t *)ct;
    if (!t || !t->serial) return nil;
    int packaged = t->has_layout && t->mem;
    id have = serial_get(t->serial);
    if (!packaged && tex_cpu_candidate(t) && !gpu_owned(t->serial) && on_sub_thread()) {   // CPU-filled (see above); uploads run on the submit thread only
        if (have) packaged = [have isKindOfClass:[NvPkg class]] || cpuf_written(t);
        else { packaged = storage_filled(t); if (!packaged) cpuf_watch(t); }
    }
    if (packaged) {
        NvPkg *pk = [have isKindOfClass:[NvPkg class]] ? have : nil;   // a watched GPU-only texture the CPU filled later gets its first upload here (serial_put retires the old one)
        if (pk) {   // Already uploaded: checked once per submission (below), the covered pages only if there has been a guest write since the last check
            // Once per submission on the submit thread: its contents are those of the submit call, as for uniform snapshots (MacNativeGames, MIT: checking at every
            // use whenever any game thread had written any page since was 4.5 % of its replay). Elsewhere (ReadTexels, present) every call checks
            int sub = on_sub_thread();
            if (sub && pk->csub == g_sub_serial && pk->tex && check_once()) return pk->tex;
#ifndef DM_TEST_PKG_AGE_FIRST   // negative control of t_uppool only: a later use not noted (the census would count from the upload)
            if (sub) pk->csub = g_sub_serial;
#endif
            uint64_t now = nvn_dirty_now(), h = 0; int clean;
            if (pk->hashed) { h = pkg_hash(t->mem, t->size); clean = h == pk->chash; }
            else {   // no guest write anywhere since the last check of a tracked texture: clean without looking its range up (a walk of all pools)
                int st = now == pk->seen && pk->tracked ? 0 : nvn_dirty_state_hint(t->mem, t->size, pk->stamp, &pk->dspan);
                clean = st == 0; pk->tracked = st != 2; pk->seen = now;
            }
            if (clean && atomic_load_explicit(&g_up_lost_n, memory_order_relaxed) && up_lost_take(pk->tex)) { clean = 0; uint64_t k = atomic_load(&g_up_lost_redo); if (k <= 3 || !atomic_load(&g_up_lost_n)) MLOG("texture from a lost upload ser=%llu re-uploaded (%llu in total, %d still recorded)", (unsigned long long)t->serial, (unsigned long long)k, atomic_load(&g_up_lost_n)); }
            if (clean) {
                if (dirtycheck() && full_hash(t->mem, t->size) != pk->hash && !g_pkg_miss++)
                    MLOG("[red] missed dirty page: texture ser=%llu pool contents changed but were not detected", t->serial);
                if (pk->spare && g_fence > pk->spare_fence + PKG_SPARE_KEEP) { defer_obj_release(pk->spare); pk->spare = nil; g_pkg_spare_drop++; }   // not re-uploaded again for a while: the spare's memory back
                return pk->tex;
            }
            { static int rl = -1; if (rl < 0) rl = getenv("DM_NVN_REUPLOG") ? atoi(getenv("DM_NVN_REUPLOG")) : 0;   // diagnostic: log the first N re-uploads
              if (rl > 0) { static _Atomic int nrl; if (atomic_fetch_add(&nrl, 1) < rl) MLOG("[reupload] ser=%llu %ux%ux%u lv%u fmt=%#x tflags=%#x pflags=%#x layout=%d storage %p size %#x frame %llu",
                  (unsigned long long)t->serial, t->d.width, t->d.height, t->d.depth, t->d.levels, t->d.format, t->d.flags, t->pool ? t->pool->flags : 0u, t->has_layout, (void *)t->mem, t->size, (unsigned long long)atomic_load(&g_cur_frame)); } }
            // Pool content changed (streamed assets written into the same storage): switch textures; in-flight draws still read the old one, which becomes
            // the spare, written by a later re-upload once its last submission has completed instead of making a new texture each time (nxnative's NvPkg
            // spare, MIT: Link's Awakening's title movie re-uploaded an 8 MB texture every frame, 1.64 -> 0.37 ms a submission)
            id<MTLTexture> reuse = pk->spare && mtl_done_fence() >= pk->spare_fence ? pk->spare : nil;
            uint64_t st; id<MTLTexture> nt = pkg_upload(t, &st, reuse);
            if (nt) { id<MTLTexture> old = pk->tex;
                      if (nt == reuse) g_pkg_spare_reuse++; else if (pk->spare) defer_obj_release(pk->spare);   // a spare still in use or of another shape: retired
                      pk->spare = old; pk->spare_fence = g_fence + 1; pk->tex = nt; res_add(nt); ser_bump(t->serial); pk->stamp = st; pk->seen = nvn_dirty_now(); pk->tracked = !pk->hashed && nvn_dirty_tracked(t->mem, t->size); if (pk->hashed) pk->chash = h; g_pkg_reuploads++; if (dirtycheck()) pk->hash = full_hash(t->mem, t->size); }
            return pk->tex;
        }
        pk = [NvPkg new]; pk->dspan = -1;
        if (counts_on()) { if (!g_pkgs) g_pkgs = [NSHashTable weakObjectsHashTable]; [g_pkgs addObject:pk]; }
        pk->tex = pkg_upload(t, &pk->stamp, nil);
        if (!pk->tex) return nil;
        pk->seen = nvn_dirty_now(); g_pkg_uploads++; if (dirtycheck()) pk->hash = full_hash(t->mem, t->size);
        if ((pk->hashed = pkg_hashed(t))) pk->chash = pkg_hash(t->mem, t->size); else pk->tracked = nvn_dirty_tracked(t->mem, t->size);
        if (on_sub_thread()) pk->csub = g_sub_serial;
        serial_put(t->serial, pk);
        return pk->tex;
    }
    if (have) return have;
    if (t->d.target == 10) {   // Buffer texture (TARGET_BUFFER): create the texture-buffer view directly on the memory pool buffer (zero copy; the GPU reads the pool's current content at execution time, same as NVN semantics)
        uint32_t pf = 0; uint8_t swz[4]; int bw, bh, bpb = nvn_fmt_bpb(t->d.format, &bw, &bh);
        void *mb; uint64_t mo;
        if (!nvn_fmt_to_mtl(t->d.format, &pf, swz) || !pf || !bpb) { RED_ONCE(36, "buffer texture format %#x not mapped", t->d.format); return nil; }
        if (!t->mem || !mtl_addr((uint64_t)t->mem, (uint64_t)t->d.width * bpb, &mb, &mo)) { RED_ONCE(37, "buffer texture storage is not in a memory pool"); return nil; }
        id<MTLBuffer> b = (__bridge id<MTLBuffer>)mb;
        NSUInteger al = [g_dev minimumLinearTextureAlignmentForPixelFormat:(MTLPixelFormat)pf];
        if (mo % al) { RED_ONCE(38, "buffer texture offset %#llx does not meet %lu-byte alignment", (unsigned long long)mo, (unsigned long)al); return nil; }
        MTLTextureDescriptor *d = [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:(MTLPixelFormat)pf width:t->d.width resourceOptions:b.resourceOptions
                                                                                         usage:MTLTextureUsageShaderRead | (t->d.flags & NVN_TEXTURE_FLAGS_IMAGE ? MTLTextureUsageShaderWrite : 0)];
        size_t row = ((size_t)t->d.width * bpb + al - 1) / al * al;
        id<MTLTexture> mt = [b newTextureWithDescriptor:d offset:mo bytesPerRow:row];
        if (!mt) { RED_ONCE(39, "cannot create buffer texture: %u elements format %#x", t->d.width, t->d.format); return nil; }
        res_add(mt);
        serial_put(t->serial, mt);
        return mt;
    }
    { id<MTLTexture> lt = tex_linear(t); if (lt) { res_add(lt); serial_put(t->serial, lt); return lt; } }
    MTLTextureDescriptor *d = tex_desc(t, 0);
    if (!d) return nil;
    { static int cls = -1; if (cls < 0) cls = getenv("DM_NVN_TEXCLASS") != NULL;   // diagnostic: a GPU-only texture's flags, its pool's flags and how much of its guest storage the CPU filled
      if (cls) { size_t nw = t->mem ? MIN((size_t)t->size, (size_t)64 << 20) / 8 : 0, nz = 0; const uint64_t *w = (const uint64_t *)(const void *)t->mem; for (size_t i = 0; i < nw; i++) nz += w[i] != 0;
          MLOG("[texclass] ser=%llu %ux%ux%u lv%u fmt=%#x tgt=%d tflags=%#x pflags=%#x storage %#x non-zero %.4f", (unsigned long long)t->serial, t->d.width, t->d.height, t->d.depth, t->d.levels,
               t->d.format, t->d.target, t->d.flags, t->pool ? t->pool->flags : 0u, t->size, nw ? (double)nz / nw : 0.0); } }
    stor_key sk; int share = stor_key_of(t, &sk);
    if (share) {   // another live (or lately left) object of this storage, layout and format: its texture
        pthread_mutex_lock(&g_smu); stor_ent *e = nvn_hm_get(&g_stor, &sk); id<MTLTexture> st = e ? (__bridge id<MTLTexture>)e->tex : nil; pthread_mutex_unlock(&g_smu);
        if (st && (st.usage & d.usage) == d.usage) {
            uint64_t n = ++g_stor_shared; if (n <= 4 || !(n % 1000)) MLOG("texture %llu (%ux%u format %#x) shares the texture of its storage with another object (%llu so far)", (unsigned long long)t->serial, t->d.width, t->d.height, t->d.format, (unsigned long long)n);
            serial_put(t->serial, st); return st; }
        if (st) g_stor_usage_miss++;   // it lacks a usage this one needs: a texture of its own, as before
    }
    id<MTLTexture> mt = [g_dev newTextureWithDescriptor:d];
    if (!mt) { RED_ONCE(2, "failed to create MTLTexture %ux%u format %#x target %d", t->d.width, t->d.height, t->d.format, t->d.target); return nil; }
    res_add(mt);
    if (share) {
        pthread_mutex_lock(&g_smu);
        if (!nvn_hm_get(&g_stor, &sk)) { stor_ent *e = calloc(1, sizeof *e); if (!e) MDIE("storage entry"); e->k = sk; e->tex = (void *)CFBridgingRetain(mt);
            uint64_t ok = (uint64_t)(uintptr_t)e->tex; nvn_hm_put(&g_stor, &sk, e); nvn_hm_put(&g_stor_obj, &ok, e);
            if (g_nstor == g_stor_cap) { g_stor_cap = g_stor_cap ? g_stor_cap * 2 : 256; g_stor_list = realloc(g_stor_list, (size_t)g_stor_cap * sizeof *g_stor_list); if (!g_stor_list) MDIE("storage list"); }
            g_stor_list[g_nstor++] = e; g_stor_entries++; }
        pthread_mutex_unlock(&g_smu);
    }
    serial_put(t->serial, mt);
    return mt;
}
// Memory readout line (always on, low frequency, capped): resident memory, GPU allocated, deferred release queue, residency set object count, registered memory pool count / peak / tracking table capacity, cumulative texture re-uploads, game heap total / free / largest allocatable block (host dm_guest_heap_stat), and how far from the system memory limit (iOS only).
// Purpose: to pin down "crashes with no log" -- the system gives no notice before killing a process for memory, and only readouts left beforehand can show which number kept climbing.
// Called by the frame hook every 300 frames; printed when resident or GPU allocated changed by >= 64 MB, or game heap free space or largest allocatable block changed by >= 16 MB (the main heap normally has only about 100 MB left), otherwise one line every 3000 frames; capped at 400 lines per run. All integers (the frame hook runs on the small stack of a guest thread, so no floating-point formatting)
static void res_census(unsigned long long frame, unsigned long long rss_mb) {
    @autoreleasepool {
        unsigned long nl[2] = {0, 0}, nr[2] = {0, 0}; unsigned long long bl[2] = {0, 0}, br[2] = {0, 0};   // [0] textures [1] buffers; l = in the residency set, r = retired but not destroyed
        pthread_mutex_lock(&g_res_mu);
        for (id o in g_res_ever.allObjects) { int k = [o conformsToProtocol:@protocol(MTLBuffer)] ? 1 : 0; unsigned long long b = (unsigned long long)[(id<MTLResource>)o allocatedSize];
            if ([g_res_objects containsObject:o]) { nl[k]++; bl[k] += b; } else { nr[k]++; br[k] += b;
                if (!k && nr[0] <= 3) { id<MTLTexture> t = o; MLOG("residency census: retired texture still alive %p %lux%lu format %lu usage %#lx (%llu MB)", (__bridge void *)o,
                    (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat, (unsigned long)t.usage, b >> 20); } } }
        pthread_mutex_unlock(&g_res_mu);
        MLOG("residency census up to frame %llu: RSS %llu MB, GPU allocated %llu MB; in the residency set: %lu textures %llu MB, %lu buffers %llu MB; retired but not destroyed: %lu textures %llu MB, %lu buffers %llu MB", frame, rss_mb, (unsigned long long)(g_dev.currentAllocatedSize >> 20),
             nl[0], bl[0] >> 20, nl[1], bl[1] >> 20, nr[0], br[0] >> 20, nr[1], br[1] >> 20);
    }
}
void dm_alias_stat(size_t *mapped_mb, size_t *host_mb); int dm_mem_low(void);
// Metal objects in the residency set by kind, for the low-memory watch (memstat.m; any thread): private render-target textures, other private textures,
// shared buffers wrapping guest memory pools (no copy: their memory is the guest's), other buffers (upload staging and the like); count and MB each,
// the deferred-release queue, and the five largest textures
static int pf_is_depth_stencil(MTLPixelFormat f) { return f == MTLPixelFormatDepth16Unorm || f == MTLPixelFormatDepth32Float || f == MTLPixelFormatStencil8 || f == MTLPixelFormatDepth32Float_Stencil8 || f == MTLPixelFormatX32_Stencil8; }
void mtl_mem_census(char *out, size_t n) { @autoreleasepool {
    unsigned long cnt[5] = {0}; unsigned long long mb[5] = {0}; struct { unsigned long long b; unsigned w, h, f, rt; } top[5] = {{0}};
    pthread_mutex_lock(&g_mu); NSMutableSet *pools = [NSMutableSet set]; for (int i = 0; i < g_npool; i++) [pools addObject:g_pools[i].buf]; pthread_mutex_unlock(&g_mu);
    pthread_mutex_lock(&g_res_mu); NSArray *all = g_res_objects.allObjects; pthread_mutex_unlock(&g_res_mu);
    for (id o in all) {
        unsigned long long b = (unsigned long long)[(id<MTLResource>)o allocatedSize]; int k;
        if ([o conformsToProtocol:@protocol(MTLTexture)]) { id<MTLTexture> t = o; int rt = (t.usage & MTLTextureUsageRenderTarget) != 0, ds = pf_is_depth_stencil(t.pixelFormat); k = rt ? (ds ? 4 : 0) : 1;
            for (int i = 0; i < 5; i++) if (b > top[i].b) { memmove(&top[i + 1], &top[i], (4 - i) * sizeof top[0]); top[i].b = b; top[i].w = (unsigned)t.width; top[i].h = (unsigned)t.height; top[i].f = (unsigned)t.pixelFormat; top[i].rt = rt; break; } }
        else k = [pools containsObject:o] ? 2 : 3;
        cnt[k]++; mb[k] += b;
    }
    pthread_mutex_lock(&g_deferred_mu); unsigned long nd = (unsigned long)g_deferred.count; pthread_mutex_unlock(&g_deferred_mu);
    size_t o = (size_t)snprintf(out, n, "color render targets %lu / %llu MB, depth/stencil render targets %lu / %llu MB, other textures %lu / %llu MB, pool buffers %lu / %llu MB, other buffers %lu / %llu MB, deferred-release queue %lu; largest textures:",
        cnt[0], mb[0] >> 20, cnt[4], mb[4] >> 20, cnt[1], mb[1] >> 20, cnt[2], mb[2] >> 20, cnt[3], mb[3] >> 20, nd);
    for (int i = 0; i < 5 && top[i].b && o < n; i++) o += (size_t)snprintf(out + o, n - o, " %ux%u fmt %u%s %llu MB", top[i].w, top[i].h, top[i].f, top[i].rt ? " RT" : "", top[i].b >> 20);
} }
unsigned long long mtl_gpu_allocated_mb(void) { id<MTLDevice> d = g_dev; return d ? (unsigned long long)(d.currentAllocatedSize >> 20) : 0; }   // GPU allocated (0 before the graphics layer starts); callable from any thread
void mtl_mem_stat(unsigned long long frame, unsigned long long rss_mb, int heap_ok, unsigned long long heap_mb, unsigned long long heap_free_mb, unsigned long long heap_maxblk_kb) {
    if (g_res_census > 0) res_census(frame, rss_mb);
    static unsigned long long last_rss, last_gpu, last_frame, last_hfree, last_hmax; static int lines; unsigned long long gpu = (unsigned long long)(g_dev.currentAllocatedSize >> 20);
    unsigned long long dr = rss_mb > last_rss ? rss_mb - last_rss : last_rss - rss_mb, dg = gpu > last_gpu ? gpu - last_gpu : last_gpu - gpu;
    unsigned long long dh = heap_free_mb > last_hfree ? heap_free_mb - last_hfree : last_hfree - heap_free_mb, hmax_mb = heap_maxblk_kb >> 10, dm = hmax_mb > last_hmax ? hmax_mb - last_hmax : last_hmax - hmax_mb;
    static int all = -1; if (all < 0) all = getenv("DM_MEM_STAT_ALL") != NULL;   // For measurement: printed every time, uncapped
    int every = all || dm_mem_low();   // also within 1 GB of the iOS memory limit (memstat.m low-memory watch): past the line cap, since the last readouts before the system kills the process are the useful ones
    if (!every && (lines >= 400 || (lines && dr < 64 && dg < 64 && dh < 16 && dm < 16 && frame - last_frame < 3000))) return; lines++; last_rss = rss_mb; last_gpu = gpu; last_frame = frame; last_hfree = heap_free_mb; last_hmax = hmax_mb;
    pthread_mutex_lock(&g_deferred_mu); unsigned long nd = (unsigned long)g_deferred.count; pthread_mutex_unlock(&g_deferred_mu);
    pthread_mutex_lock(&g_res_mu); unsigned long nr = (unsigned long)g_res_objects.count; pthread_mutex_unlock(&g_res_mu);
    int live = 0, peak = 0, cap = 0; nvn_dirty_stat(&live, &peak, &cap);
    char avail[32] = "none";   // os_proc_available_memory: how far this process is from being terminated by the system for memory, iOS only; the Mac host writes "none"
#if TARGET_OS_IPHONE
    snprintf(avail, sizeof avail, "%llu MB", (unsigned long long)(os_proc_available_memory() >> 20));
#endif
    size_t am, ah; dm_alias_stat(&am, &ah);
    MLOG("memory up to frame %llu: RSS %llu MB, GPU allocated %llu MB, deferred-release queue %lu, residency set %lu, memory pools %d (peak %d / tracking table capacity %d), texture re-uploads %llu in total; game heap %llu MB, free %llu MB, largest allocatable block %llu KB%s; alias region mapped %zu MB in %zu MB of host pages; headroom to the system memory limit %s", frame, rss_mb, gpu, nd, nr, live, peak, cap, (unsigned long long)g_pkg_reuploads,
        heap_mb, heap_free_mb, heap_maxblk_kb, heap_ok ? "" : " (not read)", am, ah, avail);
}
void mtl_pkg_stats(uint64_t *uploads, uint64_t *reuploads) { *uploads = g_pkg_uploads; *reuploads = g_pkg_reuploads; }
uint64_t mtl_pkg_miss(void) { return g_pkg_miss; }
// nvnTextureFinalize: the texture stays usable for FIN_GRACE more submissions before it is released. The game may finalize a texture that commands
// it recorded earlier and submits afterwards still sample by ID (seen at a scene change); on the console the descriptor still names the storage, so
// they read its content. Serials are never reused (nvn_new_serial), so a pending release cannot hit a new texture
enum { FIN_GRACE = 16 };
typedef struct { uint64_t serial, due; } fin_t;   // due: submission index at which it is released (0 = not yet stamped by the submit thread)
static fin_t *g_fin; static int g_nfin, g_fincap; static pthread_mutex_t g_fin_mu = PTHREAD_MUTEX_INITIALIZER;
static void fin_queue_due(uint64_t serial, uint64_t due) {   // due 0: FIN_GRACE submissions after the submit thread first sees it
    pthread_mutex_lock(&g_fin_mu);
    if (g_nfin == g_fincap) { g_fincap = g_fincap ? g_fincap * 2 : 256; g_fin = realloc(g_fin, g_fincap * sizeof *g_fin); }
    g_fin[g_nfin++] = (fin_t){serial, due};
    pthread_mutex_unlock(&g_fin_mu);
}
static void fin_queue(uint64_t serial) { fin_queue_due(serial, 0); }
enum { RECREATE_GRACE = 600 };   // tex_by_id: a texture made again for an ID used after its release stays this long
static uint64_t g_late_kept, g_late_blank;
// ---------- The live texture at a storage address (MacNativeGames' live_put / nvn_tex_live_at, MIT; written anew here) ----------
// A game may finalize a texture and initialize a new one at the same storage every frame without registering its texture ID again (Tears of the
// Kingdom's transient G-buffer targets); on the console the descriptor names the memory, so the ID reads the new texture. Here the ID kept the
// finalized texture: its old content for FIN_GRACE submissions, then a blank one created again (56 "created again" red lines in play). tex_by_id
// now follows a registration whose texture was finalized to the texture living at its storage, when that one has the same shape (t_live).
// g_live: storage address → copy of the texture last initialized there and not finalized; g_dead: finalized serials not released yet; g_fin_gen
// counts finalizations (tex_by_id looks again only after one)
static nvn_hmap g_live = {.klen = 8}, g_dead = {.klen = 8}; static pthread_mutex_t g_live_mu = PTHREAD_MUTEX_INITIALIZER; static _Atomic uint64_t g_fin_gen, g_live_follows;
static uint64_t g_alias_n;   // textures initialized over the storage of one not finalized (two live textures sharing storage: MacNativeGames' stor_*)
void mtl_tex_live(const tex_t *t) {   // hle_nvn.c nvnTextureInitialize
    if (!t->mem || !t->serial) return;
    uint64_t k = (uint64_t)(uintptr_t)t->mem; tex_t *c = malloc(sizeof *c); if (!c) MDIE("live texture"); *c = *t;
    pthread_mutex_lock(&g_live_mu);
    tex_t *old = nvn_hm_put(&g_live, &k, c);
    if (old && old->serial != t->serial && !nvn_hm_get(&g_dead, &old->serial)) {
        uint64_t n = ++g_alias_n;
        if (n <= 8 || !(n % 1000)) MLOG("texture %llu (%ux%ux%u format %#x flags %#x) initialized over the storage of live texture %llu (%ux%ux%u format %#x flags %#x): two textures share storage (%llu so far)",
            (unsigned long long)t->serial, t->d.width, t->d.height, t->d.depth, t->d.format, t->d.flags, (unsigned long long)old->serial, old->d.width, old->d.height, old->d.depth, old->d.format, old->d.flags, (unsigned long long)n);
    }
    pthread_mutex_unlock(&g_live_mu); free(old);
}
static void live_finalized(const tex_t *t) {   // nvnTextureFinalize (mtl_tex_release)
    pthread_mutex_lock(&g_live_mu);
    uint64_t s = t->serial; nvn_hm_put(&g_dead, &s, (void *)1);
    if (t->mem) { uint64_t k = (uint64_t)(uintptr_t)t->mem; tex_t *cur = nvn_hm_get(&g_live, &k); if (cur && cur->serial == t->serial) free(nvn_hm_del(&g_live, &k)); }
    pthread_mutex_unlock(&g_live_mu);
    atomic_fetch_add(&g_fin_gen, 1);
}
static void live_released(uint64_t serial) { pthread_mutex_lock(&g_live_mu); nvn_hm_del(&g_dead, &serial); pthread_mutex_unlock(&g_live_mu); }   // fin_drain
static int live_follow(const tex_t *reg, int released, tex_t *out) {   // the texture to read for a registration of reg, when reg was finalized and replaced
    if (!reg->mem) return 0;
    uint64_t k = (uint64_t)(uintptr_t)reg->mem, s = reg->serial; int ok = 0;
    pthread_mutex_lock(&g_live_mu);
    if (released || nvn_hm_get(&g_dead, &s)) {
        const tex_t *cur = nvn_hm_get(&g_live, &k);
        ok = cur && cur->serial != reg->serial && cur->size == reg->size && cur->d.format == reg->d.format && cur->d.width == reg->d.width && cur->d.height == reg->d.height &&
             cur->d.depth == reg->d.depth && cur->d.target == reg->d.target && cur->d.levels == reg->d.levels && cur->d.samples == reg->d.samples && cur->d.flags == reg->d.flags;
        if (ok) *out = *cur;
    }
    pthread_mutex_unlock(&g_live_mu);
    return ok;
}
static void treg_drop_views(const uint64_t *serials, int n);
// Host copies of texture objects for recorded commands, one per serial (hle_nvn.c records them). A command (render targets, copies, clears) records
// which texture it uses; NVN puts what a command needs into command memory when it is recorded, so the game may finalize or reuse its NVNtexture
// before the command is submitted. Recording the game's pointer let replay read whatever was there by then (a garbage format at a scene load, a
// driver crash in a copy encoder). Commands point at this copy instead; it is freed SNAP_KEEP submissions after the texture's release (fin_drain),
// long after any command recorded before the finalize has been submitted
enum { SNAP_BUCKETS = 4096, SNAP_KEEP = 600 };   // SNAP_KEEP: about 10 s at 60 fps
typedef struct snap { struct snap *next; uint64_t due; tex_t t; } snap_t;
static snap_t *g_snap[SNAP_BUCKETS], *g_snap_old, **g_snap_old_tail = &g_snap_old; static pthread_mutex_t g_snap_mu = PTHREAD_MUTEX_INITIALIZER; static uint64_t g_snap_live;   // g_snap_old: released copies in due order (FIFO)
const tex_t *mtl_tex_snap(const tex_t *t) {
    if (!t || !t->serial) return t;   // not a texture this layer initialized: kept as is (replay reports it)
    pthread_mutex_lock(&g_snap_mu);
    snap_t **b = &g_snap[t->serial % SNAP_BUCKETS], *e = *b;
    while (e && e->t.serial != t->serial) e = e->next;
    if (!e && (e = malloc(sizeof *e))) { e->t = *t; e->due = 0; e->next = *b; *b = e; g_snap_live++; }
    pthread_mutex_unlock(&g_snap_mu);
    return e ? &e->t : t;
}
static void tex_snap_retire(uint64_t serial, uint64_t due) {   // the texture was released: its copy is freed at submission index due
    pthread_mutex_lock(&g_snap_mu);
    for (snap_t **b = &g_snap[serial % SNAP_BUCKETS]; *b; b = &(*b)->next)
        if ((*b)->t.serial == serial) { snap_t *e = *b; *b = e->next; e->due = due; e->next = NULL; *g_snap_old_tail = e; g_snap_old_tail = &e->next; break; }   // dues only grow: appended in order
    pthread_mutex_unlock(&g_snap_mu);
}
static void tex_snap_reap(uint64_t now) {
    pthread_mutex_lock(&g_snap_mu);
    // From the head until the first copy not due (the list was walked whole every submission: 0.7 ms with 18,000 copies in Tears of the Kingdom)
    while (g_snap_old && g_snap_old->due <= now) { snap_t *e = g_snap_old; g_snap_old = e->next; free(e); g_snap_live--; }
    if (!g_snap_old) g_snap_old_tail = &g_snap_old;
    pthread_mutex_unlock(&g_snap_mu);
}
uint64_t mtl_tex_snap_count(void) { pthread_mutex_lock(&g_snap_mu); uint64_t n = g_snap_live; pthread_mutex_unlock(&g_snap_mu); return n; }
static void blk_drop(uint64_t serial);   // a finalized compressed render target's auxiliary texture
static void fin_drain(void) {   // submit thread, at the start of a submission
    uint64_t due[64]; int n = 0;
    tex_snap_reap(g_sub_serial); stor_sweep();
    pthread_mutex_lock(&g_fin_mu);
    for (int i = 0; i < g_nfin;) {
        if (!g_fin[i].due) g_fin[i].due = g_sub_serial + FIN_GRACE;
        if (g_fin[i].due <= g_sub_serial && n < 64) { due[n++] = g_fin[i].serial; g_fin[i] = g_fin[--g_nfin]; } else i++;
    }
    pthread_mutex_unlock(&g_fin_mu);
    // Each serial's steps in the order they always ran; the views of all of them in one walk of the registrations (one walk per serial cost 0.28 ms
    // a submission in Tears of the Kingdom: 30 releases × 33,000 registrations)
    for (int i = 0; i < n; i++) serial_del(due[i]);
    treg_drop_views(due, n);
    for (int i = 0; i < n; i++) { blk_drop(due[i]); tex_snap_retire(due[i], g_sub_serial + SNAP_KEEP); live_released(due[i]); wb_released(due[i]); }
}
void mtl_tex_release(tex_t *t) { if (t->serial) { live_finalized(t); fin_queue(t->serial); tex_forget_serial(t->serial); } }

// ---------- Render passes: SetRenderTargets opens a new pass; clears before the first command in the pass are folded into the load action ----------
static struct {
    p_set_rt rt; int has_rt;
    uint8_t clear_c[8]; MTLClearColor cc[8];
    uint8_t clear_d, clear_s; double cd; uint32_t cs;
    p_scissor sc; int has_sc;
} R;

// ---------- Zero-source skip ----------
// Shader fact table (statically proven keys): 'the textures it samples are all 0 and the coefficient is finite ⇒ the output is all 0'. Coefficient = component comp of vector vec of fragment-stage constant buffer register ubo_slot.
//   4a819818b8e489c5 ps_outline_blur_p: output = (sum of several samples of the same texture along a row / column) × fp_c7._m0[1].x (fp_c7 = cbuf reg 4), homogeneous linear in the sampled values, no constant term
//   (source of the proof: dmsh_b/<chain version>/4a819818b8e489c5_b.metal, read line by line). Add other shaders here once they are proven.
typedef struct { char key[17]; int ubo_slot, vec, comp; } zskip_fact;
static zskip_fact g_zskip_facts[16];
static int g_zskip_nf;
void zskip_test_add(const char *key, int ubo_slot, int vec, int comp) {
    if (!key || g_zskip_nf >= 16) return;
    snprintf(g_zskip_facts[g_zskip_nf].key, sizeof g_zskip_facts[0].key, "%s", key);
    g_zskip_facts[g_zskip_nf].ubo_slot = ubo_slot; g_zskip_facts[g_zskip_nf].vec = vec; g_zskip_facts[g_zskip_nf].comp = comp; g_zskip_nf++;
}
int zskip_test_count(void) { return g_zskip_count; }
static int g_zskip_env = -1;   // Cache of DM_NVN_ZSKIP (−1 = not read). This function is called on every draw, and getenv once took about 8% of the submit path; unit tests set it back to −1 after toggling the switch mid-run
static int zskip_on(void) { if (g_zskip_env < 0) { const char *e = getenv("DM_NVN_ZSKIP"); g_zskip_env = !e || strcmp(e, "0"); } return g_zskip_env && tbdr_on(); }
static void zskip_clear(void) { g_zskip_n = 0; memset(g_zskip_cand_ok, 0, sizeof g_zskip_cand_ok); }
static void zskip_del(uint64_t ser) { for (int i = 0; i < g_zskip_n;) if (g_zskip_zero[i].ser == ser) g_zskip_zero[i] = g_zskip_zero[--g_zskip_n]; else i++; }
static int zskip_has(uint64_t ser, int lv, int sl) { for (int i = 0; i < g_zskip_n; i++) if (g_zskip_zero[i].ser == ser && g_zskip_zero[i].level == lv && g_zskip_zero[i].slice == sl) return 1; return 0; }
static void zskip_add(uint64_t ser, int lv, int sl) { if (!ser || zskip_has(ser, lv, sl) || g_zskip_n >= 4096) return; g_zskip_zero[g_zskip_n++] = (zskip_zero){ser, (uint16_t)lv, (uint16_t)sl}; }
static int zskip_zero_clear(int i) { return R.clear_c[i] && R.cc[i].red == 0 && R.cc[i].green == 0 && R.cc[i].blue == 0 && R.cc[i].alpha == 0; }
static void zskip_commit_clears(void) { for (int i = 0; i < 8; i++) if (g_zskip_cand_ok[i]) zskip_add(g_zskip_cand[i].ser, g_zskip_cand[i].level, g_zskip_cand[i].slice); }
static int zskip_target_zero(const tex_t *t, const view_t *v, int hv) { int lv = hv && v->set_levels ? v->base_level : 0, sl = hv && v->set_layers ? v->min_layer : 0; return t && zskip_has(t->serial, lv, sl); }
static RENC g_enc;
// Target info of the current render pass: determined once from the attachments at rp_begin and shared by all draws in the pass (pipeline key, depth-stencil, viewport / scissor all depend only on it)
static struct { uint32_t cfmt[8], dfmt, sfmt, samples; int hd, hs; NSUInteger tw, th; uint64_t serial, reg_gen, ser_gen, range_dirty; int range_external, range_depth_nonro; __unsafe_unretained id<MTLTexture> range_color, range_depth; } g_pass;
static id<MTLRenderPipelineState> g_enc_pso; static id<MTLDepthStencilState> g_enc_dss;   // Already set on this encoder (not set again if identical)
static int g_enc_vis, g_enc_has_vis;   // This encoder's current visibility count mode (0 off / slot number + 1), and whether a visibility buffer is attached
static int g_pso_dirty = 1, g_dss_dirty = 1;   // Pipeline / depth-stencil related state was changed during replay
static uint64_t g_stat_args_enc, g_stat_args_reuse;   // Argument buffer: new-encode / reuse counts
static uint64_t g_stat_draw, g_stat_pass, g_bw_load, g_bw_store, g_pass_full_rw, g_udc_saved_bytes;   // Bandwidth ledger: attachment load / store bytes, number of full load-store passes
// DM_NVN_PASSDUMP: records pass attachments / samples / presents one by one (textures by serial) for offline data-flow analysis; the pass numbers of P / D / R / S lines agree (= g_stat_pass after the pass is opened)
// DM_NVN_PASSDUMP=frame number, or start-end (inclusive at both ends)
// The command channel's "passdump <n>" (host/cmdchan.c) sets the range to the next n frames while the game runs
static _Atomic long g_pd_a0 = -2, g_pd_a1;
static int passdump(void) {
    long a0 = atomic_load(&g_pd_a0);
    if (a0 == -2) { const char *e = getenv("DM_NVN_PASSDUMP"); long b0 = e ? atol(e) : -1, b1 = e && strchr(e, '-') ? atol(strchr(e, '-') + 1) : b0;
        long exp = -2; if (atomic_compare_exchange_strong(&g_pd_a0, &exp, b0)) atomic_store(&g_pd_a1, b1); a0 = atomic_load(&g_pd_a0); }
    long f = (long)atomic_load(&g_cur_frame); return a0 >= 0 && f >= a0 && f <= atomic_load(&g_pd_a1);
}
void mtl_passdump_next(long n) {
    long f = (long)atomic_load(&g_cur_frame); atomic_store(&g_pd_a0, -1); atomic_store(&g_pd_a1, f + n); atomic_store(&g_pd_a0, f + 1);
    MLOG("pass records of frames %ld-%ld (command channel)", f + 1, f + n);
}
#define PD(...) do { if (passdump()) { fprintf(stderr, "[pass] F%llu ", (unsigned long long)atomic_load(&g_cur_frame)); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)
static void blit_note(void) { if (g_enc) PD("E %llu copy / buffer update ends the render pass", g_stat_pass); }
// DM_GFXUSE=<file>[:<first frame>] (default frame 1): over 30 consecutive frames from that frame, record the ranges in guest memory of the resources
// the GPU actually reads (texture storage, UBO / SSBO, vertex / index buffers), deduplicated by (kind, address, length), one line on first sight.
// Columns: kind  guest_addr  len  first_frame  tex_id  fmt  w×h
__attribute__((weak)) void dm_shot_written(const char *path, int ok) { (void)path; (void)ok; }
__attribute__((weak)) int dm_guest_heap_stat(unsigned long long *t, unsigned long long *f, unsigned long long *m) { (void)t; (void)f; (void)m; return 0; }   // hle_svc.c provides the strong definition (game main heap readout); the graphics unit tests do not link the host and cannot read it
__attribute__((weak)) void dm_alias_stat(size_t *mapped_mb, size_t *host_mb) { *mapped_mb = *host_mb = 0; }   // hle_svc.c (alias region readout)
__attribute__((weak)) int dm_mem_low(void) { return 0; }   // memstat.m (low-memory watch: under 1024 MB from the limit)
__attribute__((weak)) void dm_guest_frame_tick(void) {}   // hle_os.c provides the strong definition (DM_DETCLOCK deterministic guest clock); a no-op when graphics unit tests do not link the host
__attribute__((weak)) int dm_detclock_enabled(void) { return 0; }   // Same as above: the host's hle_os.c provides the strong definition; when graphics unit tests do not link the host, the deterministic clock is treated as off
__attribute__((weak)) uint64_t guest_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }   // Same as above: the host's hle_os.c provides the guest clock; the graphics unit tests count from the same base (mach_absolute_time)
enum { USE_OFF, USE_WAIT, USE_REC, USE_DONE };
static int g_use = -1; static FILE *g_use_f; static long g_use_f0, g_use_rows; static nvn_hmap g_use_seen = {.klen = 24};
#define USE_FRAMES 30
static void use_exit(void) {
    if (g_use == USE_WAIT) fprintf(stderr, "[dm] [red] DM_GFXUSE: never reached the start frame\n");
    else if (g_use == USE_REC) fprintf(stderr, "[dm] [red] DM_GFXUSE recorded only %ld frames (fewer than %d) before exit, file incomplete\n", (long)atomic_load(&g_cur_frame) - g_use_f0, USE_FRAMES);
    if (g_use_f) fflush(g_use_f);
}
static void use_tick(void) {   // Called on every present
    static long start;
    if (g_use < 0) { const char *e = getenv("DM_GFXUSE"), *c = e ? strrchr(e, ':') : NULL; g_use = USE_OFF;   // DM_GFXUSE=<file>[:<first frame>]
        if (e) { char path[1024]; snprintf(path, sizeof path, "%.*s", c ? (int)(c - e) : (int)strlen(e), e); start = c ? atol(c + 1) : 1;
            g_use_f = fopen(path, "w"); if (!g_use_f) { MLOG("[red] DM_GFXUSE: cannot open %s", path); return; }
            fprintf(g_use_f, "kind\tguest_addr\tlen\tfirst_frame\ttex_id\tfmt\twxh\n"); fflush(g_use_f); g_use = USE_WAIT; atexit(use_exit);
            MLOG("[gfxuse] recording %d frames from frame %ld → %s", USE_FRAMES, start, path); } }
    long f = (long)atomic_load(&g_cur_frame);
    if (g_use == USE_WAIT) {
        if (f >= start) { g_use = USE_REC; g_use_f0 = f; MLOG("[gfxuse] recording from frame %ld", f); }
    } else if (g_use == USE_REC && f - g_use_f0 >= USE_FRAMES) {
        g_use = USE_DONE; fclose(g_use_f); g_use_f = NULL;
        MLOG("[gfxuse] recording complete: frames %ld–%ld, %ld ranges after dedup", g_use_f0, f - 1, g_use_rows);
    }
}
static __attribute__((always_inline)) inline void use_rec(const char *kind, uint64_t addr, uint64_t len, int tid, const tex_t *t) {
    if (g_use != USE_REC || !addr || !len) return;
    uint64_t k[3] = {addr, len, (uint64_t)(uint8_t)kind[0]};
    if (nvn_hm_get(&g_use_seen, k)) return;
    nvn_hm_put(&g_use_seen, k, (void *)1);
    g_use_rows++;
    if (t) fprintf(g_use_f, "%s\t%#llx\t%llu\t%lld\t%d\t%#x\t%ux%u\n", kind, (unsigned long long)addr, (unsigned long long)len, (long long)atomic_load(&g_cur_frame), tid, t->d.format, t->d.width, t->d.height);
    else fprintf(g_use_f, "%s\t%#llx\t%llu\t%lld\t\t\t\n", kind, (unsigned long long)addr, (unsigned long long)len, (long long)atomic_load(&g_cur_frame));
}
static uint64_t att_bytes(id<MTLTexture> t, NSUInteger level) {
    if (!t) return 0;
    NSUInteger w = MAX(t.width >> level, 1), h = MAX(t.height >> level, 1);
    NSUInteger bpp = t.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 ? 5 : t.pixelFormat == MTLPixelFormatRGBA16Float || t.pixelFormat == MTLPixelFormatRG32Float ? 8 :
                     t.pixelFormat == MTLPixelFormatRGBA32Float ? 16 : t.pixelFormat == MTLPixelFormatR8Unorm || t.pixelFormat == MTLPixelFormatStencil8 ? 1 :
                     t.pixelFormat == MTLPixelFormatRG8Unorm || t.pixelFormat == MTLPixelFormatR16Float ? 2 : 4;
    return (uint64_t)w * h * bpp * t.sampleCount;
}
// The render attachment selects a particular mip, while MTLTexture.width/height still describe the base level. Empty attachments do not take part in the bounds.
static NSUInteger mip_extent(NSUInteger size, NSUInteger level) {
    return level < sizeof(size) * 8 ? MAX(size >> level, 1) : 1;
}
static void pass_dims(RPD *pd, NSUInteger nc, NSUInteger *w, NSUInteger *h) {
    *w = *h = 0;
    for (NSUInteger i = 0; i < nc + 2; i++) {
        MTLRenderPassAttachmentDescriptor *a = i < nc ? pd.colorAttachments[i] : i == nc ? pd.depthAttachment : pd.stencilAttachment;
        if (!a.texture) continue;
        NSUInteger aw = mip_extent(a.texture.width, a.level), ah = mip_extent(a.texture.height, a.level);
        *w = *w ? MIN(*w, aw) : aw; *h = *h ? MIN(*h, ah) : ah;
    }
    if (!*w) { *w = pd.renderTargetWidth ? pd.renderTargetWidth : 1; *h = pd.renderTargetHeight ? pd.renderTargetHeight : 1; }   // a pass without attachments: its size
}

static inline void args_dirty_all(void);
void ts_after(void);
// ---------- Store lookahead: at pass end, decide from the later commands of the same submission whether each attachment's write-back is redundant ----------
// On TBDR every attachment is written back to memory in full when the pass ends; Switch (Maxwell immediate-mode rendering) has no such cost. If an attachment is cleared in full before being read, the write-back is redundant (DontCare).
// For the decision see mtl_sub_index / sdx_decide; only what can be proven within the same submission is accepted, and anything still undecided at the end of the submission is always written back.
typedef struct { uint64_t ser, bytes; uint32_t lv, sl; int idx; uint8_t depth, state, ridx, drawn, why, load, wrote, wwhy; const char *wkey; int wslot; } sd_att;   // depth: 0 color 1 depth 2 stencil (the two parts of a combined depth-stencil texture are decided separately)   // state 0 undecided 1 needed 2 redundant; idx: color attachment index, -1 for depth
static sd_att g_sd[9]; static int g_nsd;
static int g_udc_ab = -1, g_udc_ab_on;
// Attachments this pass did not write (depth / stencil test only, color write mask 0, etc.) get their write-back changed to DontCare: the content is already in memory, saving one full write-back.
// On by default: on Mac, same-process on / off screenshots follow the same distribution as the null control; on A19 Pro, private Depth32F_S8 / RGBA8 read back after DontCare differ in 0 places.
// DM_NVN_UNWRITTEN_DC=0 turns it off (for equivalence comparison)
static int udc_on(void) {
    if (g_udc_ab < 0) { const char *e = getenv("DM_NVN_UNWRITTEN_DC"); g_udc_ab = !(e && !strcmp(e, "0"));
        const char *a = getenv("DM_NVN_UDC_AB"); if (a && !strcmp(a, "1")) { g_udc_ab = 0; g_udc_ab_on = 0; } }
    return g_udc_ab || g_udc_ab_on;
}
// Diagnostic DM_NVN_TBDR=0: turns off all TBDR optimizations (store lookahead, load elision, same-target continuation, clear-only pass hoist, on-demand depth-stencil attach); replay takes the plainest 'attach all, load all, store all' path.
// Only for equivalence comparison (the same replay run on / off, comparing the picture byte by byte), not a product configuration
static int tbdr_on(void) { static int v = -1; if (v < 0) { const char *e = getenv("DM_NVN_TBDR"), *r = getenv("DM_NVN_RULER"); v = !(e && !strcmp(e, "0")); g_ruler_truth = r && !strcmp(r, "1"); if (!v) MLOG("DM_NVN_TBDR=0: all TBDR optimizations off (the reference for equivalence checks; Tears of the Kingdom's default on the Mac, games/totk/defaults.c)"); } return v && !g_ruler_truth; }
static int rt_range_on(void) { static int v = -1; if (v < 0) { const char *e=getenv("DM_NVN_RT_RANGE"); v=e && !strcmp(e,"1"); } return v; }   // Narrow candidate, off by default
static uint64_t g_sd_dead_bytes, g_sd_n_dead, g_sd_n_all;
// ---------- Cross-submission attachment validity ledger ----------
// Entry = subresource (texture serial, level, layer) + state, surviving across submissions:
//   XV_INVALID       content was not written back / not generated and must not be read. The next touch must be a full Clear, or use as an attachment with load action DontCare / Clear; otherwise it is a violation.
//   XV_PENDING_CLEAR reserved for 'clear-only pending across submissions' (not implemented): accepts only full, unscissored clears with the write mask fully open; clearing again while pending = replace the clear value without landing it;
//                    as an attachment with load DontCare / Clear → the pending clear is voided, with load Load → changed to a Clear load; depth-stencil is recorded per plane.
// Violation = report a failure + that stable key (format / width / height / level) permanently disabled (in memory + persisted to DM_XV_FILE, read at the next launch) + all entries of the same texture deleted. The fallback can only detect, not undo (in that frame the attachment holds old content).
// Its first use: color attachments 'scanned to the end undecided' at the end of a submission are not written back (sd_finish) - conditions: its first touch in this submission is a full clear / DontCare load (reset every frame before use), it is not a window texture, and the key is not disabled.
// Switch DM_NVN_XV=0 turns it off; has no effect when tbdr_on()==0 (visual ruler ground-truth mode).
// Trial period (XV_PROBE): for a key's first XV_TRIAL times it is only 'shadow-accounted' - written back as usual, but its next touch is tracked all the same; only after XV_TRIAL consecutive compliant touches does the write-back really start being skipped.
//   On a read / Load during the trial period: only disable that key (within this process, not persisted, no failure), the picture is intact - in practice there are readers as early as the launch / menu screens (upscale target 36), and not every fresh install should get one wrong frame.
enum { XV_INVALID = 1, XV_PENDING_CLEAR = 2, XV_PROBE = 3 };
#define XV_TRIAL 3
typedef struct { uint64_t ser, tag; uint32_t lv, sl; uint8_t state; } xv_ent;
static xv_ent g_xv[64]; static int g_xv_n, g_xv_block, g_xv_init;
static uint64_t g_xv_disabled[128]; static int g_xv_ndis;
static struct { uint64_t tag; int good; } g_xv_trial[128]; static int g_xv_ntrial;   // Number of consecutive compliant touches for each key
static int xv_trial_get(uint64_t tag, int add) { for (int i = 0; i < g_xv_ntrial; i++) if (g_xv_trial[i].tag == tag) return g_xv_trial[i].good += add; if (g_xv_ntrial < 128) { g_xv_trial[g_xv_ntrial].tag = tag; return g_xv_trial[g_xv_ntrial++].good = add; } return 0; }
static uint64_t g_xv_present[128]; static int g_xv_npresent;
static uint64_t g_xv_dc, g_xv_viol;
typedef struct { uint64_t ser; uint32_t lv, sl; uint8_t good; } xv_touch;
static xv_touch g_xv_touch[128]; static int g_xv_ntouch;
static uint64_t xv_tag(const tex_t *t, uint32_t lv) { return ((uint64_t)t->d.format << 40) ^ ((uint64_t)t->d.width << 24) ^ ((uint64_t)t->d.height << 8) ^ lv; }
// Stable key (unchanged across launches, does not use the texture serial): format / width / height / level, then mixed with the formats of the color attachments of the pass where the write-back is skipped and this attachment's index - textures of the same format and size but different purpose (e.g. transmittance 27 and upscale target 36) do not share a key
static uint64_t xv_tag_pass(const tex_t *t, uint32_t lv, int idx, const p_set_rt *rt) { uint64_t h = xv_tag(t, lv) ^ ((uint64_t)(idx + 1) << 60); for (int i = 0; i < rt->n && i < 8; i++) h = (h ^ (rt->color[i] ? (uint64_t)rt->color[i]->d.format + 1 : 0)) * 0x100000001b3ull; return h; }
static void xv_init(void) {
    if (g_xv_init) return; g_xv_init = 1;
    const char *p = getenv("DM_XV_FILE"); if (!p || !*p) return;
    FILE *f = fopen(p, "r"); if (!f) return;
    char line[256], why[160]; unsigned long long tag; int ch, n = 0;
    while (fgets(line, sizeof line, f) && g_xv_ndis < 128) if (sscanf(line, "%llx\t%159[^\t]\t%d", &tag, why, &ch) >= 1) g_xv_disabled[g_xv_ndis++] = tag, n++;
    fclose(f); MLOG("read %d disable records", n);
}
static int xv_disabled(uint64_t tag) { xv_init(); for (int i = 0; i < g_xv_ndis; i++) if (g_xv_disabled[i] == tag) return 1; return 0; }
static xv_ent *xv_find(uint64_t ser, uint32_t lv, uint32_t sl) { for (int i = 0; i < g_xv_n; i++) if (g_xv[i].ser == ser && g_xv[i].lv == lv && g_xv[i].sl == sl) return &g_xv[i]; return NULL; }
static void xv_drop(uint64_t ser, uint32_t lv, uint32_t sl) { for (int i = 0; i < g_xv_n; i++) if (g_xv[i].ser == ser && g_xv[i].lv == lv && g_xv[i].sl == sl) { g_xv[i] = g_xv[--g_xv_n]; return; } }
static void xv_drop_all_of(uint64_t ser) { for (int i = 0; i < g_xv_n;) if (g_xv[i].ser == ser) g_xv[i] = g_xv[--g_xv_n]; else i++; }
static void xv_set(uint64_t ser, uint32_t lv, uint32_t sl, uint8_t state, uint64_t tag) {
    xv_init(); if (g_xv_block || xv_disabled(tag)) return;
    xv_ent *e = xv_find(ser, lv, sl); if (e) { e->state = state; e->tag = tag; return; }
    if (g_xv_n < 64) g_xv[g_xv_n++] = (xv_ent){ser, tag, lv, sl, state};
}
static void xv_violation(const xv_ent *e, const char *why) {
    xv_init();
    if (e->state == XV_PROBE) {   // Trial period: the content is still there and the picture is intact - only disable the key (this process)
        if (!xv_disabled(e->tag) && g_xv_ndis < 128) g_xv_disabled[g_xv_ndis++] = e->tag;
        PD("V xv reader seen during trial: key=%016llx tex=%llu lv=%u why=%s → key disabled", (unsigned long long)e->tag, (unsigned long long)e->ser, e->lv, why);
        xv_drop_all_of(e->ser); return; }
    g_xv_viol++;
    int seen = xv_disabled(e->tag); if (!seen && g_xv_ndis < 128) g_xv_disabled[g_xv_ndis++] = e->tag;
    MLOG("[red] xv tag=%016llx tex=%llu lv=%u sl=%u why=%s pass=%llu", (unsigned long long)e->tag, (unsigned long long)e->ser, e->lv, e->sl, why, (unsigned long long)g_stat_pass);
    const char *p = getenv("DM_XV_FILE"); if (p && *p) { FILE *f = fopen(p, "a"); if (f) { fprintf(f, "%016llx\t%s\t%llu\n", (unsigned long long)e->tag, why, (unsigned long long)g_stat_pass); fclose(f); } }
    xv_drop_all_of(e->ser);
}
static void xv_check(uint64_t ser, uint32_t lv, uint32_t sl, const char *why) { xv_ent *e = xv_find(ser, lv, sl); if (e && (e->state == XV_INVALID || e->state == XV_PROBE)) { xv_ent copy = *e; xv_violation(&copy, why); } }
static void xv_good(xv_ent *e) { if (e->state == XV_PROBE) xv_trial_get(e->tag, 1); xv_drop(e->ser, e->lv, e->sl); }   // Compliant touch: counts once toward the trial period, and the entry returns to valid
static void xv_touch_add(uint64_t ser, uint32_t lv, uint32_t sl, int good) { for (int i = 0; i < g_xv_ntouch; i++) if (g_xv_touch[i].ser == ser && g_xv_touch[i].lv == lv && g_xv_touch[i].sl == sl) return; if (g_xv_ntouch < 128) g_xv_touch[g_xv_ntouch++] = (xv_touch){ser, lv, sl, (uint8_t)good}; }
static int xv_first_good(uint64_t ser, uint32_t lv, uint32_t sl) { for (int i = 0; i < g_xv_ntouch; i++) if (g_xv_touch[i].ser == ser && g_xv_touch[i].lv == lv && g_xv_touch[i].sl == sl) return g_xv_touch[i].good; return 0; }
static int xv_present(uint64_t ser) { for (int i = 0; i < g_xv_npresent; i++) if (g_xv_present[i] == ser) return 1; return 0; }
static void xv_forward(void);
static int tbdr_on(void);
static int xv_on(void) { static int off = -1; if (off < 0) { const char *e = getenv("DM_NVN_XV"); off = e && !strcmp(e, "0"); } return !off && tbdr_on(); }
void mtl_xv_window_tex(uint64_t serial) { if (!xv_present(serial) && g_xv_npresent < 128) g_xv_present[g_xv_npresent++] = serial; }   // Window (swapchain) texture: never enters the ledger
void xv_test_counts(int *dc, int *viol) { if (dc) *dc = (int)g_xv_dc; if (viol) *viol = (int)g_xv_viol; }
static void sd_finish(void);
// Load elision (fully covering first draw): if the draw that opens the pass can be proven to cover a color attachment in full (first_draw_covers), that attachment's load becomes DontCare -
// the first draw does not blend and writes all channels, every covered pixel is rewritten by it, and the original content is not visible (Switch immediate-mode rendering has no such cost; on TBDR load = reading the whole thing from memory into the tile)
static const p_draw *g_fd_dw; static const p_draw_idx *g_fd_di;   // The draw that opens the pass (one of non-indexed / indexed); non-null only while draw() is opening a pass
static uint64_t g_fd_n;         // Cumulative number of attachments judged elidable
static int g_fd_why;            // Reason for the most recent failure (Q line of PASSDUMP: 1 no program 2 shader 3 attachment 4 blend/mask/raster 5 depth-stencil test 6 vertex count 7 position attribute 8 format/stream 9 out of bounds 10 address 11 geometry)
static int first_draw_covers(int i, id<MTLTexture> t, NSUInteger level);
static int pf_is_float(MTLPixelFormat f) {   // Float color formats that can store NaN (sentinel choice for the load-elision probe; RGB9E5 cannot store NaN and does not count)
    switch (f) { case MTLPixelFormatR16Float: case MTLPixelFormatRG16Float: case MTLPixelFormatRGBA16Float: case MTLPixelFormatR32Float:
        case MTLPixelFormatRG32Float: case MTLPixelFormatRGBA32Float: case MTLPixelFormatRG11B10Float: return 1; default: return 0; }
}
static int fz_load_covers(int i, id<MTLTexture> t, NSUInteger level);
static NSMutableArray *g_lp;    // DM_NVN_LOADPROBE=1 / 2 / 3 (two constant sentinel values / NaN - under float formats normal shader output cannot reach NaN, ruling out numeric coincidence): attachments judged elidable are cleared to the sentinel color instead, and at pass end the remaining sentinel pixels are read back and counted (diagnostic: should be 0)
static void lp_finish(void);
// Same-target continuation: when the game calls SetRenderTargets again on the same set of targets (with no copy / dispatch / clear in between) the pass is not ended - on TBDR this saves one full write-back + load.
// Basis for equivalence: NVN's Barrier between two passes requires the latter to see all writes of the former. Within one Metal render encoder, later draws' reads and writes of the attachment itself (blend, depth / stencil test)
// are ordered with earlier draws in submission order; but 'sampling' the attachment texture is not covered (reading and writing the same attachment within one pass is undefined). So continuation happens only when later draws do not sample these attachments:
// if during continuation a draw needs to sample them, or a clear arrives, the pass is ended before it, returning to the separate semantics. Copies / dispatches end the render encoder anyway
static int g_enc_mode;          // How the current encoder was opened (rp_begin_ex argument: 0 all attachments 1 only for clears 2 depth omitted)
// Layered render passes (lay_decide): a pass opened on one layer of a small cube / 2D array level covers the layers that the following SetRenderTargets
// of the same texture, level and view draw into; each draw goes to its layer through the vertex amplification view mapping (no shader change). Method
// from MacNativeGames' layered passes (ly05010419/MacNativeGames, MIT; it patches the vertex functions to write the layer instead), written anew here
enum { LAY_MAX_EXTENT = 256, PSO_LAYERED = 1u << 8 };   // PSO_LAYERED: in pso_key.a2c (bit 0 stays alpha to coverage)
static struct { int active, first, count, cur, amp, refuse; uint64_t ser; view_t v; uint64_t passes, merges, splits; } g_lay = {.amp = -1};
static int lay_decide(int clear_only, int *first);
static int g_rt_range_active, g_rt_range_pending;
// ---------- Mid-submission commits (MacNativeGames, MIT: TOTK_CHUNK_DRAWS; written anew here) ----------
// A game that puts a whole frame into one nvnQueueSubmitCommands had the replay of the frame and its GPU work strictly in sequence. Where an encoder is
// about to open and none is open, the work encoded so far is committed as a command buffer of its own once enough draws went into it, and the
// submission goes on in a fresh one (same allocator), so the GPU starts on the first passes while the replay encodes the rest. Every encoder opens
// with a queue barrier, which orders it after all earlier work on the queue, across command buffers too; this submission's uploads are flushed
// first. The fence, the counter / query write-backs, the arena and the deferred releases stay with the last command buffer (mtl_sub_commit).
// MacNativeGames' uncapped world-scene frame means: 150/500 draws 12.50 ms, 60/75 11.66 ms. Not while the TBDR rewrites are on (their lookahead and
// merged passes span the submission; MacNativeGames turns them off for Tears of the Kingdom). DM_NVN_CHUNK_DRAWS=<n> (default 75, 0 = off),
// DM_NVN_CHUNK_FIRST=<n> (default 60)
static int g_chunk_first = -1, g_chunk_size, g_sub_chunks; static uint64_t g_chunk_mark, g_chunk_commits;
static void chunk_cfg(void) {
    if (g_chunk_first >= 0) return;
    const char *e = getenv("DM_NVN_CHUNK_DRAWS"), *f = getenv("DM_NVN_CHUNK_FIRST");
    g_chunk_size = e ? atoi(e) : 75; g_chunk_first = f ? atoi(f) : 60;
    if (g_chunk_size <= 0 || g_chunk_first <= 0) g_chunk_size = g_chunk_first = 0;
    if (g_chunk_size && !tbdr_on()) MLOG("mid-submission commits: after %d draws, then every %d draws (DM_NVN_CHUNK_DRAWS=0 turns them off)", g_chunk_first, g_chunk_size);
}
static void mtl_sub_split(void) {
    up_flush(); res_commit(); rs_sync();
    uint64_t gpu_f = atomic_load(&g_cur_frame), fence_next = g_fence + 1; gpu_tag_begin(gpu_f);
    atomic_fetch_add(&g_inflight, 1);
#if DM_NVN_M3
    [g_cb addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        gpu_tag_done(gpu_f, cb.GPUStartTime, cb.GPUEndTime);
        if (cb.error) { atomic_store(&g_last_commit_error, 1); static int n; if (n++ < 8) MLOG("[red] command buffer error in a part of submission %llu: %s", (unsigned long long)fence_next, cb.error.description.UTF8String); }
        if (atomic_fetch_sub(&g_inflight, 1) == 1 && g_ka_idle) dispatch_semaphore_signal(g_ka_idle); }];
    [g_cb commit]; cb_committed();
    g_cb = [g_q commandBuffer];
#else
    MTL4CommitOptions *o = [MTL4CommitOptions new];
    [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) {
        gpu_tag_done(gpu_f, f.GPUStartTime, f.GPUEndTime);
        if (f.error) { atomic_store(&g_last_commit_error, 1); static int n; if (n++ < 8) MLOG("[red] command buffer error in a part of submission %llu: %s", (unsigned long long)fence_next, f.error.description.UTF8String); }
        if (atomic_fetch_sub(&g_inflight, 1) == 1 && g_ka_idle) dispatch_semaphore_signal(g_ka_idle); }];
    [g_cb endCommandBuffer];
    CBUF buffers[] = {g_cb}; [g_q4 commit:buffers count:1 options:o]; cb_committed();
    g_cb = [g_dev newCommandBuffer]; [g_cb beginCommandBufferWithAllocator:g_alloc4[g_alloc_cur]];
#endif
    g_sub_chunks++; g_chunk_commits++; g_chunk_mark = g_stat_draw;
}
static void chunk_maybe_split(void) {   // where a new encoder is about to open and none is open
    chunk_cfg();
    if (!g_chunk_size || !g_cb || g_enc || g_rt_range_active || tbdr_on()) return;
    if (g_stat_draw - g_chunk_mark < (uint64_t)(g_sub_chunks ? g_chunk_size : g_chunk_first)) return;
    if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    mtl_sub_split();
}
uint64_t mtl_chunk_commits(void) { return g_chunk_commits; }
static void chunk_reset(void) { g_sub_chunks = 0; g_chunk_mark = g_stat_draw; }   // mtl_sub_begin
static int g_rt_merged;         // The current pass has already been continued (at least one same-target SetRenderTargets was merged in)
static uint64_t g_rt_merge_n;   // Cumulative continuation count
static int g_defer_replaying;
static void fz_end(void);   // Wrap-up of the readable-tile pass merge (defined before draw)
static void defer_fallback(void);
// ---------- DM_NVN_PASSGPU=<file>: GPU time of each render pass and dispatch (plan item 49) ----------
// After upstream 44a6770 (jhaizhou-ops/d2r-mobile, MIT), written for this replay. Metal 4 writes timestamps into an MTL4CounterHeap: after the
// render encoder opens (before the vertex stage of its first draw) and before it ends (after the fragment stage of its draws), and around each
// dispatch (precise: dispatches share the copy encoder); Metal 3 samples at stage boundaries through the pass descriptors. A heap per submission in
// a ring of 8, cleared before reuse; the submission's feedback resolves it. One row per pass: frame idx kind gpu_ms inc_ms w h fmt0 dfmt load
// draws t0_ns t1_ns pass (kind R render / C dispatch; load: L load / C clear per colour attachment, | then depth; pass: the number in
// DM_NVN_PASSDUMP's lines). Passes overlap on the GPU (a pass's vertex stage, the start Metal 3 samples, runs during the previous pass's
// fragments: a light pass after a heavy one spans 13 ms on Metal 3, 0.01 ms on Metal 4), so gpu_ms (start to end) does not add up; inc_ms =
// end − max(start, the latest end before it) does, to the time the GPU was busy. Every 300 frames a line gives the passes' GPU time a frame and
// the five kinds of pass (size, formats, loads) that took the most of it (a pass's index in the frame is no identity: Tears of the Kingdom's
// frames have 100-260 passes; summed by index they came to 13 ms a frame against 6.4 ms of increments).
typedef struct { uint64_t frame, pass; int idx, kind, w, h, draws, slot; uint32_t cfmt0, dfmt; char load[12]; } pg_pass;
#define PG_SLOTS 4096
#define PG_RING 8
static int g_pgt = -1; static FILE *g_pgt_f;
#if DM_NVN_M3
static id<MTLCounterSampleBuffer> g_pgt_buf[PG_RING];
#define PG_RSLOTS 4   // vertex start / end, fragment start / end
#else
static id<MTL4CounterHeap> g_pgt_buf[PG_RING]; static double g_pgt_ns_tick = 1;
#define PG_RSLOTS 2
#endif
static uint32_t g_pgt_ring_used[PG_RING];
static int g_pgt_b; static uint32_t g_pgt_used;
static pg_pass *g_pgt_pass; static int g_pgt_np, g_pgt_cap, g_pgt_open = -1;
static uint64_t g_pgt_frame = ~0ull; static int g_pgt_idx;
static pthread_mutex_t g_pgt_mu = PTHREAD_MUTEX_INITIALIZER;
typedef struct { int kind, w, h; uint32_t cfmt0, dfmt; char load[12]; double sum; uint64_t n; } pg_sig;   // one kind of pass in the window
static pg_sig g_pgt_sig[512]; static int g_pgt_nsig; static uint64_t g_pgt_rep_frame, g_pgt_win_last = ~0ull, g_pgt_win_frames, g_pgt_win_n; static double g_pgt_win_ms;
static void pg_window(const pg_pass *p, double inc) {   // (under g_pgt_mu) one row into the window; every 300 frames its line
    if (p->frame != g_pgt_win_last) { g_pgt_win_last = p->frame; g_pgt_win_frames++; }
    g_pgt_win_ms += inc; g_pgt_win_n++;
    int k = 0; while (k < g_pgt_nsig && !(g_pgt_sig[k].kind == p->kind && g_pgt_sig[k].w == p->w && g_pgt_sig[k].h == p->h && g_pgt_sig[k].cfmt0 == p->cfmt0 && g_pgt_sig[k].dfmt == p->dfmt && !strcmp(g_pgt_sig[k].load, p->load))) k++;
    if (k == g_pgt_nsig && k < 512) { g_pgt_sig[k] = (pg_sig){p->kind, p->w, p->h, p->cfmt0, p->dfmt, "", 0, 0}; memcpy(g_pgt_sig[k].load, p->load, sizeof p->load); g_pgt_nsig++; }
    if (k < g_pgt_nsig) { g_pgt_sig[k].sum += inc; g_pgt_sig[k].n++; }
    if (p->frame < g_pgt_rep_frame + 300 || g_pgt_win_frames < 2) return;
    double nf = (double)(g_pgt_win_frames - 1);   // (the frame now starting is not whole yet)
    int top[5] = {-1, -1, -1, -1, -1};
    for (int i = 0; i < g_pgt_nsig; i++) for (int j = 0; j < 5; j++) if (top[j] < 0 || g_pgt_sig[i].sum > g_pgt_sig[top[j]].sum) { for (int q = 4; q > j; q--) top[q] = top[q - 1]; top[j] = i; break; }
    char line[1024]; size_t o = 0;
    for (int j = 0; j < 5 && top[j] >= 0 && o < sizeof line; j++) { pg_sig *g = &g_pgt_sig[top[j]];
        o += (size_t)snprintf(line + o, sizeof line - o, "%s %c %dx%d fmt %u/%u %s %.2f ms (%.1f a frame)", j ? ";" : "", g->kind ? 'C' : 'R', g->w, g->h, g->cfmt0, g->dfmt,
                              g->kind ? "-" : g->load, g->sum / nf, g->n / nf); }
    MLOG("[passgpu] up to frame %llu: passes and dispatches %.2f ms of GPU time a frame (%.0f of them); most:%s", (unsigned long long)p->frame, g_pgt_win_ms / nf, g_pgt_win_n / nf, line);
    g_pgt_rep_frame = p->frame; g_pgt_nsig = 0; g_pgt_win_frames = 1; g_pgt_win_ms = 0; g_pgt_win_n = 0; g_pgt_win_last = p->frame;
}
static int pg_on(void) {
    if (g_pgt >= 0) return g_pgt;
    const char *e = getenv("DM_NVN_PASSGPU"); g_pgt = 0;
    if (!e || !*e) return 0;
#if DM_NVN_M3
    if (![g_dev supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) { MLOG("[red] DM_NVN_PASSGPU: no counter sampling at stage boundaries on this GPU"); return 0; }
    id<MTLCounterSet> ts = nil; for (id<MTLCounterSet> c in g_dev.counterSets) if ([c.name isEqualToString:MTLCommonCounterSetTimestamp]) ts = c;
    if (!ts) { MLOG("[red] DM_NVN_PASSGPU: no timestamp counter set"); return 0; }
    MTLCounterSampleBufferDescriptor *d = [MTLCounterSampleBufferDescriptor new]; d.counterSet = ts; d.storageMode = MTLStorageModeShared; d.sampleCount = PG_SLOTS;
    for (int i = 0; i < PG_RING; i++) { NSError *er = nil; g_pgt_buf[i] = [g_dev newCounterSampleBufferWithDescriptor:d error:&er]; if (!g_pgt_buf[i]) { MLOG("[red] DM_NVN_PASSGPU: no counter sample buffer: %s", er.localizedDescription.UTF8String ?: "?"); return 0; } }
#else
    MTL4CounterHeapDescriptor *hd = [MTL4CounterHeapDescriptor new]; hd.type = MTL4CounterHeapTypeTimestamp; hd.count = PG_SLOTS;
    for (int i = 0; i < PG_RING; i++) { NSError *er = nil; g_pgt_buf[i] = [g_dev newCounterHeapWithDescriptor:hd error:&er]; if (!g_pgt_buf[i]) { MLOG("[red] DM_NVN_PASSGPU: no timestamp counter heap: %s", er.localizedDescription.UTF8String ?: "?"); return 0; } }
    { uint64_t fq = [g_dev queryTimestampFrequency]; g_pgt_ns_tick = fq ? 1e9 / (double)fq : 1; }
#endif
    if (!(g_pgt_f = fopen(e, "w"))) { MLOG("[red] DM_NVN_PASSGPU: cannot open %s", e); return 0; }
    fprintf(g_pgt_f, "frame\tidx\tkind\tgpu_ms\tinc_ms\tw\th\tfmt0\tdfmt\tload\tdraws\tt0_ns\tt1_ns\tpass\n"); fflush(g_pgt_f);
    MLOG("DM_NVN_PASSGPU: the GPU time of each render pass and dispatch → %s", e);
    return g_pgt = 1;
}
static void pg_sub_begin(uint64_t fence) {   // this submission takes heap fence % PG_RING, once the one that used it last has completed
    if (!pg_on()) return;
    if (fence > PG_RING) mtl_wait(fence - PG_RING, UINT64_MAX);
    g_pgt_b = (int)(fence % PG_RING); g_pgt_used = 0; g_pgt_np = 0; g_pgt_open = -1;
#if !DM_NVN_M3
    if (g_pgt_ring_used[g_pgt_b]) [g_pgt_buf[g_pgt_b] invalidateCounterRange:NSMakeRange(0, g_pgt_ring_used[g_pgt_b])];   // (a slot left unwritten reads 0, not an old time)
#endif
}
static pg_pass *pg_new(int kind, int nslot) {
    if (!pg_on() || g_pgt_used + (uint32_t)nslot > PG_SLOTS) return NULL;
    uint64_t f = atomic_load(&g_cur_frame); if (f != g_pgt_frame) { g_pgt_frame = f; g_pgt_idx = 0; }
    if (g_pgt_np == g_pgt_cap) { g_pgt_cap = g_pgt_cap ? g_pgt_cap * 2 : 128; g_pgt_pass = realloc(g_pgt_pass, (size_t)g_pgt_cap * sizeof *g_pgt_pass); }
    pg_pass *p = &g_pgt_pass[g_pgt_np++]; memset(p, 0, sizeof *p);
    p->frame = f; p->pass = g_stat_pass; p->idx = g_pgt_idx++; p->kind = kind; p->slot = (int)g_pgt_used; p->draws = -(int)g_stat_draw;
    g_pgt_used += (uint32_t)nslot;
    return p;
}
static void pg_render(RPD *pd, NSUInteger nc) {   // before the render encoder opens: the pass's row (and on Metal 3 its sample points)
    if (!g_pgt) return;
    pg_pass *p = pg_new(0, PG_RSLOTS); if (!p) return;
    p->pass = g_stat_pass + 1;
#if DM_NVN_M3
    MTLRenderPassSampleBufferAttachmentDescriptor *a = pd.sampleBufferAttachments[0];
    a.sampleBuffer = g_pgt_buf[g_pgt_b];
    a.startOfVertexSampleIndex = (NSUInteger)p->slot; a.endOfVertexSampleIndex = (NSUInteger)p->slot + 1; a.startOfFragmentSampleIndex = (NSUInteger)p->slot + 2; a.endOfFragmentSampleIndex = (NSUInteger)p->slot + 3;
#ifdef DM_TEST_PG_NO_END
    a.endOfVertexSampleIndex = a.endOfFragmentSampleIndex = MTLCounterDontSample;
#endif
#endif
    id<MTLTexture> t0 = nil; int k = 0;
    for (NSUInteger i = 0; i < nc && i < 8; i++) { id<MTLTexture> t = pd.colorAttachments[i].texture; if (!t) continue;
        if (!t0) t0 = t; if (k < 9) p->load[k++] = pd.colorAttachments[i].loadAction == MTLLoadActionClear ? 'C' : 'L'; }
    id<MTLTexture> dt = pd.depthAttachment.texture;
    if (dt) { if (k < 10) { p->load[k++] = '|'; p->load[k++] = pd.depthAttachment.loadAction == MTLLoadActionClear ? 'C' : 'L'; } p->dfmt = (uint32_t)dt.pixelFormat; }
    if (!k) p->load[k++] = '-';
    NSUInteger pw, ph; pass_dims(pd, nc, &pw, &ph);
    p->w = (int)pw; p->h = (int)ph; p->cfmt0 = t0 ? (uint32_t)t0.pixelFormat : 0;
    g_pgt_open = g_pgt_np - 1;
}
static void pg_render_begin(id e) {   // the encoder just opened: the pass's start
#if !DM_NVN_M3
    if (g_pgt_open >= 0 && [e conformsToProtocol:@protocol(MTL4RenderCommandEncoder)])
        [(id<MTL4RenderCommandEncoder>)e writeTimestampWithGranularity:MTL4TimestampGranularityRelaxed afterStage:MTLRenderStageVertex intoHeap:g_pgt_buf[g_pgt_b] atIndex:(NSUInteger)g_pgt_pass[g_pgt_open].slot];
#else
    (void)e;
#endif
}
static void pg_render_end(id e) {   // before the encoder ends: the pass's end and its draws
    if (g_pgt_open < 0) return;
#if !DM_NVN_M3 && !defined(DM_TEST_PG_NO_END)   // (negative control of t_passgpu: no end written)
    if ([e conformsToProtocol:@protocol(MTL4RenderCommandEncoder)])
        [(id<MTL4RenderCommandEncoder>)e writeTimestampWithGranularity:MTL4TimestampGranularityRelaxed afterStage:MTLRenderStageFragment intoHeap:g_pgt_buf[g_pgt_b] atIndex:(NSUInteger)g_pgt_pass[g_pgt_open].slot + 1];
#else
    (void)e;
#endif
    g_pgt_pass[g_pgt_open].draws += (int)g_stat_draw; g_pgt_open = -1;
}
#if DM_NVN_M3
static MTLComputePassDescriptor *pg_compute_desc(void) {   // a dispatch's own encoder, sampled at its start and end
    pg_pass *p = g_pgt ? pg_new(1, 2) : NULL; if (!p) return nil;
    p->draws = 0;
    MTLComputePassDescriptor *cd = [MTLComputePassDescriptor computePassDescriptor];
    cd.sampleBufferAttachments[0].sampleBuffer = g_pgt_buf[g_pgt_b];
    cd.sampleBufferAttachments[0].startOfEncoderSampleIndex = (NSUInteger)p->slot;
#ifndef DM_TEST_PG_NO_END
    cd.sampleBufferAttachments[0].endOfEncoderSampleIndex = (NSUInteger)p->slot + 1;
#else
    cd.sampleBufferAttachments[0].endOfEncoderSampleIndex = MTLCounterDontSample;
#endif
    return cd;
}
#else
static int pg_dispatch_begin(CENC ce) {   // a dispatch in the shared encoder: precise timestamps around it
    pg_pass *p = g_pgt ? pg_new(1, 2) : NULL; if (!p) return -1;
    p->draws = 0;
    [ce writeTimestampWithGranularity:MTL4TimestampGranularityPrecise intoHeap:g_pgt_buf[g_pgt_b] atIndex:(NSUInteger)p->slot];
    return p->slot + 1;
}
static void pg_dispatch_end(CENC ce, int slot) {
#ifndef DM_TEST_PG_NO_END
    if (slot >= 0) [ce writeTimestampWithGranularity:MTL4TimestampGranularityPrecise intoHeap:g_pgt_buf[g_pgt_b] atIndex:(NSUInteger)slot];
#else
    (void)ce; (void)slot;
#endif
}
#endif
static void pg_commit(id fb) {   // the submission's rows go to its feedback (fb = FB_ON(o, g_cb)), which resolves the heap
    if (g_pgt <= 0 || !g_pgt_np) return;
    int n = g_pgt_np; pg_pass *ps = malloc((size_t)n * sizeof *ps); memcpy(ps, g_pgt_pass, (size_t)n * sizeof *ps);
    __typeof__(g_pgt_buf[0]) buf = g_pgt_buf[g_pgt_b]; uint32_t used = g_pgt_used; g_pgt_ring_used[g_pgt_b] = used;
#if !DM_NVN_M3
    double ns_tick = g_pgt_ns_tick;
#endif
    [fb FB_SEL:^(FB_ARG c) {
        (void)c;
        NSData *d = [buf resolveCounterRange:NSMakeRange(0, used)];
        uint64_t *t = d ? calloc(used ? used : 1, sizeof *t) : NULL;   // each sample point's time in ns, 0 = not written
#if DM_NVN_M3
        const MTLCounterResultTimestamp *r = d.bytes;
        for (uint32_t k = 0; t && k < used && (k + 1) * sizeof *r <= d.length; k++) t[k] = r[k].timestamp == MTLCounterErrorValue ? 0 : r[k].timestamp;
#else
        const MTL4TimestampHeapEntry *r = d.bytes;
        for (uint32_t k = 0; t && k < used && (k + 1) * sizeof *r <= d.length; k++) t[k] = (uint64_t)(r[k].timestamp * ns_tick);
#endif
        pthread_mutex_lock(&g_pgt_mu);
        for (int i = 0; t && i < n; i++) {
            pg_pass *p = &ps[i]; uint64_t a, b;
#if DM_NVN_M3
            if (p->kind == 0) { a = t[p->slot] ? t[p->slot] : t[p->slot + 2]; b = t[p->slot + 3] ? t[p->slot + 3] : t[p->slot + 1]; }
            else { a = t[p->slot]; b = t[p->slot + 1]; }
#else
            a = t[p->slot]; b = t[p->slot + 1];
#endif
            if (!a || !b || b < a) continue;
            static uint64_t prev_end;   // the latest end so far (feedback runs in submission order)
            double ms = (b - a) / 1e6, inc = b > prev_end ? (b - (a > prev_end ? a : prev_end)) / 1e6 : 0;
            if (b > prev_end) prev_end = b;
            fprintf(g_pgt_f, "%llu\t%d\t%c\t%.4f\t%.4f\t%d\t%d\t%u\t%u\t%s\t%d\t%llu\t%llu\t%llu\n", (unsigned long long)p->frame, p->idx, p->kind ? 'C' : 'R', ms, inc,
                    p->w, p->h, p->cfmt0, p->dfmt, p->kind ? "-" : p->load, p->draws, (unsigned long long)a, (unsigned long long)b, (unsigned long long)p->pass);
            pg_window(p, inc);
        }
        fflush(g_pgt_f);
        pthread_mutex_unlock(&g_pgt_mu);
        free(t); free(ps);
    }];
}
// DM_NVN_ENC_LABEL=1: label every render encoder with 'p<index of the render pass within the frame> <width>x<height> <first 8 digits of the first draw's fragment key> d<draw count>'; in Instruments (xctrace Game Performance / Metal System Trace)
// the encoder track and the GPU interval table carry this name directly, and shader_map.tsv maps it back to the shader; off by default (one string allocation per pass)
static int g_el_w, g_el_h, g_el_draws; static char g_el_key[12];
static int g_nblk_wb; static void blk_writeback(void);
static int enc_label_on(void) { static int v = -1; if (v < 0) { const char *e = getenv("DM_NVN_ENC_LABEL"); v = e && atoi(e); } return v; }
static int g_fbx_nact; static inline void args_dirty_all(void);
static void rp_end(void) { if (g_fbx_nact) { g_fbx_nact = 0; args_dirty_all(); }   // the attachment copies of a draw stand in only for it (fbx_prepare)
    if (g_enc) {
    if (g_cnt_on > 0 && g_stat_draw == g_cnt_pass_d0) g_cnt_nodraw++;
    if (g_cnt_on > 0 && g_cnt_ext_x) { uint64_t tw = g_pass.tw, th = g_pass.th, ew = MIN(g_cnt_ext_x, tw), eh = MIN(g_cnt_ext_y, th); g_cnt_rp++; g_cnt_rp_px += tw * th;
        if (ew < tw || eh < th) { if (g_cnt_ext_clr) g_cnt_rp_outc += tw * th - ew * eh; else g_cnt_rp_out += tw * th - ew * eh;
            if ((g_cnt_ext_clr ? g_cnt_rp_subc++ : g_cnt_rp_sub++) < 12) MLOG("[counts] pass %llu %llux%llu%s: its draws reach %llux%llu (%d colour targets, depth %d)", (unsigned long long)g_stat_pass,
                (unsigned long long)tw, (unsigned long long)th, g_cnt_ext_clr ? " (a clear on load)" : "", (unsigned long long)ew, (unsigned long long)eh, R.rt.n, R.rt.depth != NULL); } }
    g_cnt_ext_x = g_cnt_ext_y = 0;
    if (enc_label_on()) { static uint64_t lf = ~0ull, base; uint64_t f = atomic_load(&g_cur_frame); if (f != lf) { lf = f; base = g_stat_pass - 1; }   // Intra-frame serial: the same pass has the same name every frame, so the table can aggregate by name
        [(id)g_enc setLabel:[NSString stringWithFormat:@"p%02llu %dx%d %s d%d", (unsigned long long)(g_stat_pass - base), g_el_w, g_el_h, g_el_key[0] ? g_el_key : "-", g_el_draws]]; }
    sd_finish(); pg_render_end(g_enc); enc_r_end(g_enc); zskip_commit_clears(); g_enc = nil; g_rt_merged = 0; g_lay.active = 0; g_rt_range_active = g_rt_range_pending = 0; ts_after(); if (g_lp.count) lp_finish(); fz_end();
    if (g_nblk_wb) blk_writeback();   // blocks rendered into auxiliary textures → the compressed textures
} }
// A compressed texture as a render target (Tears of the Kingdom, as nxnative found in Breath of the Wild: a BC4 texture written through an RGBA16UI
// view, one texel = one 8-byte block, i.e. BC4 encoded on the GPU): Metal can neither attach a compressed format as a colour attachment nor make
// compressed <-> uncompressed views (pipeline descriptor validation aborts the process). The pass renders into an auxiliary texture in the view's
// format, one texel per block, and the blocks are copied into the compressed texture through a buffer when the pass ends (blk_aux; nxnative, seedds,
// MIT; MacNativeGames, ly05010419, MIT). Any other view of a compressed render target is left out with a red line (its draws land nowhere)
static int mtl_fmt_block(MTLPixelFormat f) { return (f >= MTLPixelFormatBC1_RGBA && f <= MTLPixelFormatBC7_RGBAUnorm_sRGB) || (f >= MTLPixelFormatPVRTC_RGB_2BPP && f < MTLPixelFormatGBGR422); }
static int mtl_bc_block_bytes(MTLPixelFormat f) {   // bytes per 4x4 block of a BC format, 0 for other formats
    switch (f) { case MTLPixelFormatBC1_RGBA: case MTLPixelFormatBC1_RGBA_sRGB: case MTLPixelFormatBC4_RUnorm: case MTLPixelFormatBC4_RSnorm: return 8;
        case MTLPixelFormatBC2_RGBA: case MTLPixelFormatBC2_RGBA_sRGB: case MTLPixelFormatBC3_RGBA: case MTLPixelFormatBC3_RGBA_sRGB: case MTLPixelFormatBC5_RGUnorm:
        case MTLPixelFormatBC5_RGSnorm: case MTLPixelFormatBC6H_RGBFloat: case MTLPixelFormatBC6H_RGBUfloat: case MTLPixelFormatBC7_RGBAUnorm: case MTLPixelFormatBC7_RGBAUnorm_sRGB: return 16;
        default: return 0; }
}
// The format a BC render target is drawn in: the view's, when it is uncompressed with one block per texel (0 otherwise)
static MTLPixelFormat blk_view_fmt(id<MTLTexture> base, const view_t *v, int has_v) {
    int bb = base ? mtl_bc_block_bytes(base.pixelFormat) : 0, vbw = 0, vbh = 0; uint32_t vpf = 0; uint8_t swz[4];
    if (!bb || !has_v || !v->set_format || nvn_fmt_bpb(v->format, &vbw, &vbh) != bb || vbw != 1 || vbh != 1 || !nvn_fmt_to_mtl(v->format, &vpf, swz) || !vpf || mtl_fmt_block((MTLPixelFormat)vpf)) return MTLPixelFormatInvalid;
    return (MTLPixelFormat)vpf;
}
// The format a colour attachment is actually attached with: the view's format if the view changes the format and it can be attached, otherwise the base texture's format (shared by attaching and pipeline prediction, so both agree). warn: log red when it cannot be attached
static MTLPixelFormat rt_color_fmt(id<MTLTexture> base, const view_t *v, int has_v, int warn) {
    if (base && mtl_fmt_block(base.pixelFormat)) {
        MTLPixelFormat bf = blk_view_fmt(base, v, has_v);
        if (bf != MTLPixelFormatInvalid) return bf;
        if (warn) RED_ONCE(71, "render target is a compressed texture (Metal format %lu, %lux%lu, view format %#x) without a view of one block per texel: not attached, its draws land nowhere (first case)",
                           (unsigned long)base.pixelFormat, (unsigned long)base.width, (unsigned long)base.height, has_v && v->set_format ? v->format : 0);
        return MTLPixelFormatInvalid;
    }
    if (!base || !has_v || !v->set_format) return base.pixelFormat;
    uint32_t pf = 0; uint8_t swz[4];
    if (!nvn_fmt_to_mtl(v->format, &pf, swz) || !pf) return base.pixelFormat;
    if (pf != (uint32_t)base.pixelFormat && tex_need_pfv(base.pixelFormat, (MTLPixelFormat)pf) && !(base.usage & MTLTextureUsagePixelFormatView)) {
        if (warn) RED_ONCE(48, "render target view format %#x cannot be attached (base texture %lu lacks the pixel-format-view usage), drawing in the base format (first case)", v->format, (unsigned long)base.pixelFormat);
        return base.pixelFormat; }
    return (MTLPixelFormat)pf;
}
// color: when the view of a colour attachment changes the format (e.g. an RGBA8 base texture written through an RGBA8_SRGB view), attach a Metal view of that format - on the Switch writes and clears are encoded by the view's format,
// and attaching only the base texture drops the sRGB encoding entirely, making the picture too dark (public repository #36, measured by seedds on another game); the pipeline colour formats take the attached texture's format (g_pass.cfmt), so they follow.
// The view lives only until this submission completes (Metal 4 does not retain resources; the view shares storage with the base texture and is not made resident separately). Depth / stencil attachments do not change format
// The same level / layer of one texture attached at more than one colour slot: only one slot is attached, the others are left out (their writes are
// dropped). On the Switch the ROP writes only the channels a slot's write mask enables, so the slots do not interfere; on Apple's TBDR every attachment
// has its own tile memory and is stored back whole at the end of the pass, so the copy stored later (loaded or cleared, never written) overwrites the
// other one's writes. Breath of the Wild's G-buffer attaches the albedo twice (nxnative, seedds, upstream d6cd8a8, MIT); Tears of the Kingdom's
// half-resolution lighting passes attach their RG11B10F light buffer at c2 and c3, and the stored zeros left the title mural unlit (black). The slot
// kept is the one the pass's opening draw writes (write mask non-zero), else the first: tomodachi-native's variant (kuosuko, MIT), since a pass may
// write only through a later slot. A pending clear on a slot left out moves to the slot kept; a draw writing a slot left out is reported once.
static uint32_t cur_chmask(void);   // the current channel write mask (S.chmask, defined with the draw state)
static uint8_t g_rt_dup_skip;       // slots this pass left out
static int rt_same_sub(const p_set_rt *r, int i, int j) {   // the two slots attach the same level / layer of one texture
    if (!r->color[i] || !r->color[j] || r->color[j]->serial != r->color[i]->serial) return 0;   // by serial: records hold copies of the texture objects
    uint8_t lv = r->has_cview[i] && r->cview[i].set_levels ? r->cview[i].base_level : 0; uint16_t ly = r->has_cview[i] && r->cview[i].set_layers ? r->cview[i].min_layer : 0;
    uint8_t lj = r->has_cview[j] && r->cview[j].set_levels ? r->cview[j].base_level : 0; uint16_t yj = r->has_cview[j] && r->cview[j].set_layers ? r->cview[j].min_layer : 0;
    return lj == lv && yj == ly;
}
static int rt_dup_slot(const p_set_rt *r, int i) {
    if (!r->color[i]) return 0;
    uint32_t cm = cur_chmask(); int first = -1, pick = -1, n = 0;
    for (int j = 0; j < r->n && j < 8; j++) if (rt_same_sub(r, i, j)) { if (first < 0) first = j; if (pick < 0 && (cm >> (4 * j) & 0xf)) pick = j; n++; }
    return n > 1 && i != (pick >= 0 ? pick : first);
}
typedef struct { __unsafe_unretained id<MTLTexture> aux, dst; NSUInteger level, slice, plane, lw, lh, bx, by, bpb; } blk_wb;   // plane: depth plane of a 3D texture
static NSMutableDictionary<NSNumber *, id<MTLTexture>> *g_blkaux;   // texture serial → auxiliary block texture (dropped when the texture is finalized)
static blk_wb g_blk_wb[8];                                          // the open pass's attachments to copy back at rp_end (count g_nblk_wb)
// Copies one level / slice between the compressed texture and its auxiliary texture through a buffer (Metal copies whole blocks between a BC texture and
// a buffer, and texels between an uncompressed texture and a buffer: the same bytes). from_aux: auxiliary → compressed, else compressed → auxiliary
static void blk_copy(id<MTLTexture> from, int from_aux, id<MTLTexture> to, const blk_wb *w) {
    NSUInteger row = w->bx * w->bpb, size = row * w->by;
    id<MTLBuffer> b = [g_dev newBufferWithLength:size options:MTLResourceStorageModePrivate];
    if (!b) { RED_ONCE(79, "block render target copy buffer of %lu bytes not allocated (first case)", (unsigned long)size); return; }
    res_add(b);
    BENC e = blit();
    MTLSize blocks = MTLSizeMake(w->bx, w->by, 1), texels = MTLSizeMake(w->lw, w->lh, 1);
    enc_b_copy_texture_buffer(e, from, w->slice, w->level, MTLOriginMake(0, 0, w->plane), from_aux ? blocks : texels, b, 0, row, size);
#if !DM_NVN_M3
    [e barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
#endif
    enc_b_copy_buffer_texture(e, b, 0, row, size, from_aux ? texels : blocks, to, w->slice, w->level, MTLOriginMake(0, 0, w->plane));
    defer_obj_release(b);
}
// The auxiliary texture attachment i renders into (nil when the attachment is not a BC texture with a block-sized view), *w filled for the copies
static id<MTLTexture> blk_aux(const tex_t *t, const view_t *v, int has_v, blk_wb *w) {
    id<MTLTexture> base = tex_mtl(t);
    if (!base || !mtl_fmt_block(base.pixelFormat)) return nil;
    MTLPixelFormat vpf = blk_view_fmt(base, v, has_v);
    if (vpf == MTLPixelFormatInvalid) return nil;   // attach() reports it
    tex_gpu_write(t); base = tex_mtl(t);            // as attach(): the first GPU write can replace a CPU-filled texture's MTLTexture
    if (!base) return nil;
    int is3d = base.textureType == MTLTextureType3D;
    if (base.textureType != MTLTextureType2D && base.textureType != MTLTextureType2DArray && !is3d) { RED_ONCE(79, "compressed render target of texture type %lu not drawn (first case)", (unsigned long)base.textureType); return nil; }
    if (!g_blkaux) g_blkaux = [NSMutableDictionary dictionary];
    NSNumber *key = @(t->serial); id<MTLTexture> a = g_blkaux[key];
    NSUInteger aw = (base.width + 3) / 4, ah = (base.height + 3) / 4;
    if (!a || a.pixelFormat != vpf || a.width != aw || a.height != ah) {
        if (a) defer_obj_release(a);
        MTLTextureDescriptor *d = [MTLTextureDescriptor new];
        d.textureType = base.textureType; d.pixelFormat = vpf; d.width = aw; d.height = ah;
        d.arrayLength = base.arrayLength; d.depth = base.depth; d.mipmapLevelCount = base.mipmapLevelCount;
        d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        a = [g_dev newTextureWithDescriptor:d];
        if (!a) { RED_ONCE(79, "auxiliary block render texture %lux%lu not allocated (first case)", (unsigned long)aw, (unsigned long)ah); return nil; }
        res_add(a); g_blkaux[key] = a;
        static int once; if (!once++) MLOG("render target on a compressed texture (Metal format %lu, %lux%lu) drawn through its view format %lu into a %lux%lu block texture, copied back after the pass (first case)",
                                           (unsigned long)base.pixelFormat, (unsigned long)base.width, (unsigned long)base.height, (unsigned long)vpf, (unsigned long)aw, (unsigned long)ah);
    }
    NSUInteger lv = v->set_levels ? v->base_level : 0, sl = v->set_layers ? v->min_layer : 0;
    NSUInteger lw = MAX(base.width >> lv, 1u), lh = MAX(base.height >> lv, 1u);
    if (lv >= base.mipmapLevelCount) { RED_ONCE(79, "compressed render target level %lu of %lu not drawn (first case)", (unsigned long)lv, (unsigned long)base.mipmapLevelCount); return nil; }
    *w = (blk_wb){a, base, lv, is3d ? 0 : sl, is3d ? sl : 0, lw, lh, (lw + 3) / 4, (lh + 3) / 4, (NSUInteger)mtl_bc_block_bytes(base.pixelFormat)};
    return a;
}
static void blk_writeback(void) { int n = g_nblk_wb; g_nblk_wb = 0; for (int i = 0; i < n; i++) blk_copy(g_blk_wb[i].aux, 1, g_blk_wb[i].dst, &g_blk_wb[i]); }
static void blk_drop(uint64_t serial) { if (!g_blkaux) return; NSNumber *k = @(serial); id<MTLTexture> a = g_blkaux[k]; if (a) { defer_obj_release(a); [g_blkaux removeObjectForKey:k]; } }
static void attach(MTLRenderPassAttachmentDescriptor *a, const tex_t *t, const view_t *v, int has_v, int color) {
    tex_gpu_write(t);
    id<MTLTexture> base = tex_mtl(t); a.texture = base;
    if (color && base && mtl_fmt_block(base.pixelFormat)) { if (blk_view_fmt(base, v, has_v) == MTLPixelFormatInvalid) rt_color_fmt(base, v, has_v, 1); a.texture = nil; return; }   // see mtl_fmt_block: rp_begin attaches the auxiliary texture
    if (has_v && v->set_levels) a.level = v->base_level;
    if (has_v && v->set_layers) { if (t->d.target == 2) a.depthPlane = v->min_layer; else a.slice = v->min_layer; }
    if (!color || !base) return;
    MTLPixelFormat pf = rt_color_fmt(base, v, has_v, 1);
    if (pf == base.pixelFormat) return;
    id<MTLTexture> vw = [base newTextureViewWithPixelFormat:pf];
    if (!vw) { RED_ONCE(49, "cannot create render target view: format %#x (base texture %lu), drawing in the base format (first case)", v->format, (unsigned long)base.pixelFormat); return; }
    a.texture = vw; defer_obj_unref(vw);
    { static int once; if (!once++) MLOG("render target attached through a format-changing view: view format %#x, base texture %lu → attached %lu (first case)", v->format, (unsigned long)base.pixelFormat, (unsigned long)pf); }
}
// mode 1 (clear_only): a pass opened only to land pending clears, attaching only the attachments that have clears; mode 2: the lookahead proves this pass does not use depth-stencil, so depth is not attached.
// clear_only: a pass opened only to land pending clears, attaching only the attachments that have clears - the other attachments are not touched by this pass, and attaching them costs a pointless load and store on TBDR
// (Mac character select screen: the color-clear pass drags along a 400x225 depth load and store)
static RENC rp_begin_ex(int clear_only);
static RENC rp_begin(void) { return rp_begin_ex(0); }
static RENC rp_begin_ex(int clear_only) {
    if (g_enc) return g_enc;
    memset(g_zskip_cand_ok, 0, sizeof g_zskip_cand_ok);
    g_enc_mode = clear_only;
    if (!R.has_rt) { RED_ONCE(3, "no render target set before draw"); return nil; }
    int lay_first = 0, lay_n = lay_decide(clear_only, &lay_first);
    // The version of the attachment-range candidate is taken before capturing any attachment; if it changes during setup, there is no continuation.
    uint64_t reg0 = 0, ser0 = 0, dirty0 = 0;
    if (rt_range_on()) { reg0 = g_reg_gen; ser0 = g_ser_gen; }
    if (rt_range_on()) dirty0=nvn_dirty_now();
    int any = 0; g_rt_dup_skip = 0;
    for (int i = 0; i < R.rt.n && i < 8; i++) if (R.clear_c[i] && rt_dup_slot(&R.rt, i))   // a pending clear on a slot left out goes to the slot kept (see rt_dup_slot)
        for (int j = 0; j < R.rt.n && j < 8; j++) if (j != i && rt_same_sub(&R.rt, i, j) && !rt_dup_slot(&R.rt, j)) { if (!R.clear_c[j]) { R.clear_c[j] = 1; R.cc[j] = R.cc[i]; } break; }
    blk_wb pre[8]; id<MTLTexture> preaux[8] = {nil};   // compressed render targets: auxiliary textures, loaded with the old blocks unless cleared (a blit, before the render encoder)
    for (int i = 0; i < R.rt.n && i < 8; i++) {
        if (!R.rt.color[i] || (clear_only == 1 && !R.clear_c[i]) || rt_dup_slot(&R.rt, i)) continue;
        preaux[i] = blk_aux(R.rt.color[i], &R.rt.cview[i], R.rt.has_cview[i], &pre[i]);
        if (preaux[i] && !R.clear_c[i]) blk_copy(pre[i].dst, 0, preaux[i], &pre[i]);
    }
    if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    RPD *pd = [RPD new];
    for (int i = 0; i < R.rt.n; i++) {
        if (!R.rt.color[i] || (clear_only == 1 && !R.clear_c[i])) continue;
        if (i < 8 && rt_dup_slot(&R.rt, i)) { g_rt_dup_skip |= (uint8_t)(1u << i); PD("P %llu c%d ser=%llu left out: the same texture is attached at another slot", g_stat_pass + 1, i, R.rt.color[i]->serial); continue; }
        if (i < 8 && preaux[i]) {
            pd.colorAttachments[i].texture = preaux[i]; pd.colorAttachments[i].level = pre[i].level;
            if (preaux[i].textureType == MTLTextureType3D) pd.colorAttachments[i].depthPlane = pre[i].plane; else pd.colorAttachments[i].slice = pre[i].slice;
            if (g_nblk_wb < 8) g_blk_wb[g_nblk_wb++] = pre[i];
        } else attach(pd.colorAttachments[i], R.rt.color[i], &R.rt.cview[i], R.rt.has_cview[i], 1);
        if (!pd.colorAttachments[i].texture) continue;
        any = 1;
        pd.colorAttachments[i].loadAction = R.clear_c[i] ? MTLLoadActionClear : MTLLoadActionLoad;
        pd.colorAttachments[i].clearColor = R.cc[i];
        { static long long rtc = -2; if (rtc == -2) { const char *e = getenv("DM_NVN_RTCLEAR"); rtc = e ? atoll(e) : -1; }   // diagnostic: passes on this colour serial start cleared to magenta (does the attachment reach the texture?)
          if (rtc >= 0 && R.rt.color[i]->serial == (uint64_t)rtc) { pd.colorAttachments[i].loadAction = MTLLoadActionClear; pd.colorAttachments[i].clearColor = MTLClearColorMake(1, 0, 1, 1); } }
        int cov = tbdr_on() && !R.clear_c[i] && (g_fd_dw || g_fd_di) && fz_load_covers(i, pd.colorAttachments[i].texture, pd.colorAttachments[i].level);
        if (!R.clear_c[i] && (g_fd_dw || g_fd_di) && !cov) PD("Q %llu c%d load not elidable why=%d", g_stat_pass + 1, i, g_fd_why);
        if (cov) {
            static int probe = -1; if (probe < 0) { probe = getenv("DM_NVN_LOADPROBE") ? atoi(getenv("DM_NVN_LOADPROBE")) : 0; if (probe) MLOG("DM_NVN_LOADPROBE: attachments with an elidable load are cleared to a sentinel color instead and read back for verification"); }
            if (probe) { pd.colorAttachments[i].loadAction = MTLLoadActionClear; int pm = probe == 1 && pf_is_float(pd.colorAttachments[i].texture.pixelFormat) ? 3 : probe;   // Float formats use a NaN sentinel by default: a fixed sentinel value can be hit by real output (it has been hit in practice)
                pd.colorAttachments[i].clearColor = pm == 3 ? MTLClearColorMake(NAN, NAN, NAN, NAN) : probe == 2 ? MTLClearColorMake(0.777, 0.222, 0.555, 0.888) : MTLClearColorMake(0.123, 0.456, 0.789, 0.321);
                if (!g_lp) g_lp = [NSMutableArray array];
                [g_lp addObject:@[pd.colorAttachments[i].texture, @(pd.colorAttachments[i].level), @(pd.colorAttachments[i].slice), @(g_stat_pass + 1), @(i), @(R.rt.color[i]->serial), @(pm)]]; }
            else pd.colorAttachments[i].loadAction = MTLLoadActionDontCare;
            g_fd_n++;
        }
        xv_touch_add(R.rt.color[i]->serial, (uint32_t)pd.colorAttachments[i].level, (uint32_t)pd.colorAttachments[i].slice,
                     pd.colorAttachments[i].loadAction != MTLLoadActionLoad);
        if (g_xv_n) { xv_ent *xe = xv_find(R.rt.color[i]->serial, (uint32_t)pd.colorAttachments[i].level, (uint32_t)pd.colorAttachments[i].slice);
            if (xe && (xe->state == XV_INVALID || xe->state == XV_PROBE)) { if (pd.colorAttachments[i].loadAction == MTLLoadActionLoad) { xv_ent copy = *xe; xv_violation(&copy, "loads old contents as an attachment"); } else xv_good(xe); } }
        pd.colorAttachments[i].storeAction = MTLStoreActionStore;
    }
    // clear_only: 0 attach all 1 only for clears 2 neither depth nor stencil attached 3 stencil only 4 depth only (3 / 4: the pass_ds_need lookahead proves the whole pass uses only that one)
    if (R.rt.depth && clear_only == 3) {   // Stencil only: the depth plane of the combined format does not enter the tile and is neither read nor written (Metal allows an empty depth attachment with the combined texture on the stencil attachment)
        attach(pd.stencilAttachment, R.rt.depth, &R.rt.dview, R.rt.has_dview, 0);
        MTLPixelFormat pf = pd.stencilAttachment.texture.pixelFormat;
        if (pf == MTLPixelFormatDepth32Float_Stencil8 || pf == MTLPixelFormatStencil8) {
            any = 1; pd.stencilAttachment.loadAction = R.clear_s ? MTLLoadActionClear : MTLLoadActionLoad;
            pd.stencilAttachment.clearStencil = R.cs; pd.stencilAttachment.storeAction = MTLStoreActionStore;
        } else pd.stencilAttachment.texture = nil;   // No stencil plane: the stencil test always passes, attach nothing
    } else if (R.rt.depth && clear_only != 2 && !(clear_only == 1 && !R.clear_d && !R.clear_s)) {
        attach(pd.depthAttachment, R.rt.depth, &R.rt.dview, R.rt.has_dview, 0);
        if (pd.depthAttachment.texture) {
            any = 1;
            pd.depthAttachment.loadAction = R.clear_d ? MTLLoadActionClear : MTLLoadActionLoad;
            MTLPixelFormat pf = pd.depthAttachment.texture.pixelFormat;
            pd.depthAttachment.clearDepth = pf == MTLPixelFormatDepth16Unorm ? nvn_depth16_clear_value(R.cd) : R.cd; pd.depthAttachment.storeAction = MTLStoreActionStore;
            if (clear_only != 4 && (pf == MTLPixelFormatDepth32Float_Stencil8 || pf == MTLPixelFormatStencil8)) {   // 4: depth only
                pd.stencilAttachment.texture = pd.depthAttachment.texture; pd.stencilAttachment.level = pd.depthAttachment.level;
                pd.stencilAttachment.slice = pd.depthAttachment.slice;
                pd.stencilAttachment.loadAction = R.clear_s ? MTLLoadActionClear : MTLLoadActionLoad;
                pd.stencilAttachment.clearStencil = R.cs; pd.stencilAttachment.storeAction = MTLStoreActionStore;
            }
        }
    }
    // Nothing attached although the pass draws: no colour or depth target at all (NVN rasterizes without attachments, side effects through storage
    // buffers / images; Tears of the Kingdom draws one under a 1x1 scissor), or only a depth target the look-ahead proved unused (mode 2; its
    // occlusion query draws). Metal: a pass with only a size, the depth target's, else the scissor's
    if (!any && (clear_only == 0 || clear_only == 2) && (!R.rt.depth || clear_only == 2)) {
        int none = 1;
        for (int i = 0; i < R.rt.n && i < 8; i++) none &= !R.rt.color[i];
        if (none) {
            NSUInteger w = R.has_sc ? (NSUInteger)MAX((int64_t)R.sc.x + R.sc.w, 1) : 1, h = R.has_sc ? (NSUInteger)MAX((int64_t)R.sc.y + R.sc.h, 1) : 1;
            if (R.rt.depth) { NSUInteger lv = R.rt.has_dview && R.rt.dview.set_levels ? R.rt.dview.base_level : 0; w = mip_extent(R.rt.depth->d.width, lv); h = mip_extent(R.rt.depth->d.height, lv); }
            pd.renderTargetWidth = MIN(w, 16384u); pd.renderTargetHeight = MIN(h, 16384u); pd.defaultRasterSampleCount = 1; any = 1;
            static int once[2]; if (!once[!!R.rt.depth]++) MLOG("render pass without attachments, %lux%lu from the %s (first case)", (unsigned long)pd.renderTargetWidth, (unsigned long)pd.renderTargetHeight, R.rt.depth ? "unused depth target" : "scissor");
        }
    }
    if (!any) {
        if (!g_red_once[4]) { char d[400] = ""; size_t o = 0;
            for (int i = 0; i < R.rt.n && i < 8; i++) if (R.rt.color[i]) { id<MTLTexture> m = tex_mtl(R.rt.color[i]);
                o += snprintf(d + o, sizeof d - o, " c%d ser %llu fmt %#x %ux%u view %#x mtl %lu%s;", i, (unsigned long long)R.rt.color[i]->serial, R.rt.color[i]->d.format, R.rt.color[i]->d.width, R.rt.color[i]->d.height,
                              R.rt.has_cview[i] && R.rt.cview[i].set_format ? R.rt.cview[i].format : 0, (unsigned long)m.pixelFormat, rt_dup_slot(&R.rt, i) ? " dup" : ""); if (o >= sizeof d) break; }
            if (o < sizeof d) snprintf(d + o, sizeof d - o, " depth %s, clear_only %d, occlusion counting %d, scissor %dx%d", R.rt.depth ? "set" : "none", clear_only, g_vis_on,
                                      R.has_sc ? R.sc.w : -1, R.has_sc ? R.sc.h : -1);
            RED_ONCE(4, "none of the render targets can create an MTLTexture:%s", d); }
        return nil; }
    for (int i = 0; i < R.rt.n && i < 8; i++) if (R.rt.color[i] && zskip_zero_clear(i)) {
        g_zskip_cand_ok[i] = 1; g_zskip_cand[i] = (zskip_zero){R.rt.color[i]->serial, (uint16_t)(R.rt.has_cview[i] && R.rt.cview[i].set_levels ? R.rt.cview[i].base_level : 0), (uint16_t)(R.rt.has_cview[i] && R.rt.cview[i].set_layers ? R.rt.cview[i].min_layer : 0)};
    }
    // Bandwidth ledger: attachments with Load count as load, all attachments count as store (currently always Store)
    int nload = 0, natt = 0;
    for (int i = 0; i < R.rt.n; i++) {
        MTLRenderPassColorAttachmentDescriptor *c = pd.colorAttachments[i];
        if (!c.texture) continue;
        uint64_t b = att_bytes(c.texture, c.level); natt++; g_bw_store += b; if (c.loadAction == MTLLoadActionLoad) { g_bw_load += b; nload++; }
        if (R.rt.has_cview[i] && R.rt.cview[i].set_format) PD("V %llu c%d view format %#x (base texture NVN format %#x)", g_stat_pass + 1, i, R.rt.cview[i].format, R.rt.color[i]->d.format);
        PD("P %llu c%d ser=%llu fmt=%lu %lux%lu ms%lu lv%lu sl%lu %s %g,%g,%g,%g", g_stat_pass + 1, i, R.rt.color[i]->serial, (unsigned long)c.texture.pixelFormat,
           (unsigned long)c.texture.width, (unsigned long)c.texture.height, (unsigned long)c.texture.sampleCount, (unsigned long)c.level, (unsigned long)c.slice,
           c.loadAction == MTLLoadActionClear ? "clear" : c.loadAction == MTLLoadActionDontCare ? "dontcare" : "load", c.clearColor.red, c.clearColor.green, c.clearColor.blue, c.clearColor.alpha);
    }
    {   // Depth and stencil planes are counted separately (combined format 5 bytes = depth 4 + stencil 1; when only one is attached only that one is counted)
        id<MTLTexture> dt = pd.depthAttachment.texture, stt = pd.stencilAttachment.texture;
        uint64_t whole = att_bytes(dt ? dt : stt, dt ? pd.depthAttachment.level : pd.stencilAttachment.level);
        int comb = (dt ? dt : stt).pixelFormat == MTLPixelFormatDepth32Float_Stencil8;
        uint64_t db = dt ? (comb ? whole / 5 * 4 : whole) : 0, sb = stt && stt != dt ? (comb ? whole / 5 : whole) : stt ? whole - db : 0;
        if (dt) { natt++; g_bw_store += db; if (pd.depthAttachment.loadAction == MTLLoadActionLoad) { g_bw_load += db; nload++; } }
        if (stt) { natt += !dt; g_bw_store += sb; if (pd.stencilAttachment.loadAction == MTLLoadActionLoad) { g_bw_load += sb; nload += !dt; } }
        if (dt) PD("P %llu d ser=%llu fmt=%lu %lux%lu %s", g_stat_pass + 1, R.rt.depth->serial, (unsigned long)dt.pixelFormat,
                   (unsigned long)dt.width, (unsigned long)dt.height, pd.depthAttachment.loadAction == MTLLoadActionClear ? "clear" : "load");
        else if (stt) PD("P %llu s ser=%llu fmt=%lu %lux%lu %s (stencil only)", g_stat_pass + 1, R.rt.depth->serial, (unsigned long)stt.pixelFormat,
                   (unsigned long)stt.width, (unsigned long)stt.height, pd.stencilAttachment.loadAction == MTLLoadActionClear ? "clear" : "load");
    }
    if (natt && nload == natt) g_pass_full_rw++;
    g_nsd = 0;
    {
        for (int i = 0; i < R.rt.n && i < 8; i++) { MTLRenderPassColorAttachmentDescriptor *c = pd.colorAttachments[i]; if (!c.texture) continue;
            g_sd[g_nsd] = (sd_att){0}; g_sd[g_nsd].ser = R.rt.color[i]->serial; g_sd[g_nsd].bytes = att_bytes(c.texture, c.level); g_sd[g_nsd].lv = (uint32_t)c.level; g_sd[g_nsd].sl = (uint32_t)(c.texture.textureType == MTLTextureType3D ? c.depthPlane : c.slice); g_sd[g_nsd].idx = i; g_sd[g_nsd].load = c.loadAction == MTLLoadActionLoad; g_sd[g_nsd].wrote = R.clear_c[i] != 0; g_nsd++;
            c.storeAction = MTLStoreActionUnknown; }
        id<MTLTexture> dt = pd.depthAttachment.texture, stt = pd.stencilAttachment.texture;
        uint64_t db = att_bytes(dt, pd.depthAttachment.level), sb = 0;
        if (stt) { int comb = stt.pixelFormat == MTLPixelFormatDepth32Float_Stencil8; sb = att_bytes(stt, pd.stencilAttachment.level) / (comb ? 5 : 1); if (stt == dt) db -= sb; }   // Combined format 5 bytes = depth 4 + stencil 1 (when only stencil is attached, only 1 is counted)
        if (dt) { g_sd[g_nsd] = (sd_att){0}; g_sd[g_nsd].ser = R.rt.depth->serial; g_sd[g_nsd].bytes = db; g_sd[g_nsd].lv = (uint32_t)pd.depthAttachment.level; g_sd[g_nsd].sl = (uint32_t)pd.depthAttachment.slice; g_sd[g_nsd].idx = -1; g_sd[g_nsd].depth = 1; g_sd[g_nsd].load = pd.depthAttachment.loadAction == MTLLoadActionLoad; g_sd[g_nsd].wrote = R.clear_d != 0; g_nsd++;
                  pd.depthAttachment.storeAction = MTLStoreActionUnknown; }
        if (stt) { g_sd[g_nsd] = (sd_att){0}; g_sd[g_nsd].ser = R.rt.depth->serial; g_sd[g_nsd].bytes = sb; g_sd[g_nsd].lv = (uint32_t)pd.stencilAttachment.level; g_sd[g_nsd].sl = (uint32_t)pd.stencilAttachment.slice; g_sd[g_nsd].idx = -1; g_sd[g_nsd].depth = 2; g_sd[g_nsd].load = pd.stencilAttachment.loadAction == MTLLoadActionLoad; g_sd[g_nsd].wrote = R.clear_s != 0; g_nsd++;
                   pd.stencilAttachment.storeAction = MTLStoreActionUnknown; }
    }
    memset(R.clear_c, 0, sizeof R.clear_c); R.clear_d = R.clear_s = 0;
    {   // Pass info (same convention as the former per-draw fetch: colors take each attachment's base texture format; sample count takes the last color attachment, or depth if there is depth)
        uint64_t ser = g_pass.serial + 1; memset(&g_pass, 0, sizeof g_pass); g_pass.serial = ser;
        for (int i = 0; i < R.rt.n && i < 8; i++) { id<MTLTexture> t = R.rt.color[i] ? pd.colorAttachments[i].texture : nil;
            if (t) { g_pass.cfmt[i] = (uint32_t)t.pixelFormat; g_pass.samples = (uint32_t)t.sampleCount; } }
        id<MTLTexture> dt = R.rt.depth ? pd.depthAttachment.texture : nil, stt = R.rt.depth ? pd.stencilAttachment.texture : nil;   // Depth / stencil attachments are fetched separately (possibly only one of them is attached)
        g_pass.hd = dt && dt.pixelFormat != MTLPixelFormatStencil8; g_pass.hs = stt != nil;
        g_pass.dfmt = g_pass.hd ? (uint32_t)dt.pixelFormat : 0; g_pass.sfmt = stt ? (uint32_t)stt.pixelFormat : 0;
        if (dt || stt) g_pass.samples = (uint32_t)(dt ? dt : stt).sampleCount;
        pass_dims(pd, (NSUInteger)R.rt.n, &g_pass.tw, &g_pass.th);
        if (rt_range_on()) { g_pass.reg_gen = reg0; g_pass.ser_gen = ser0; }
        if (rt_range_on()) { g_pass.range_dirty=dirty0; g_pass.range_color=pd.colorAttachments[0].texture; g_pass.range_depth=pd.depthAttachment.texture; }
        g_enc_pso = nil; g_enc_dss = nil;
    }
    if (g_vis_on) {
        // Slots used up (one submission exceeds VIS_SLOTS counting passes): create an overflow buffer and continue with it. Buffers in the ring must not be handed to retirement (they are still used in rotation, and retiring would remove them from the residency set);
        // only the previous overflow buffer may be retired. The overflow buffer itself is retired when the next submission switches back to a ring buffer (mtl_sub_begin)
        if (!g_vis || g_vis_n >= VIS_SLOTS) { if (g_vis && !vis_in_ring(g_vis)) defer_obj_release(g_vis); g_vis = [g_dev newBufferWithLength:VIS_SLOTS * 8 options:MTLResourceStorageModeShared]; res_add(g_vis); g_vis_n = 0; }
        pd.visibilityResultBuffer = g_vis;
    }
    g_enc_vis = 0; g_enc_has_vis = g_vis_on;
    { void td_note(id pd, NSUInteger nc); td_note(pd, (NSUInteger)R.rt.n);
      void ts_note(id pd, NSUInteger nc); ts_note(pd, (NSUInteger)R.rt.n); }
    if (lay_n > 1 && pd.colorAttachments[0].texture) {   // the attachment covers the layer range; the draws pick their layer (lay_route)
        pd.colorAttachments[0].slice = (NSUInteger)lay_first; pd.renderTargetArrayLength = (NSUInteger)lay_n;
        g_lay.active = 1; g_lay.first = lay_first; g_lay.count = lay_n; g_lay.cur = R.rt.cview[0].min_layer; g_lay.amp = -1;
        g_lay.ser = R.rt.color[0]->serial; g_lay.v = R.rt.cview[0];
        if (!g_lay.passes++) MLOG("layered pass: first one covers layers %d-%d of a %lux%lu level", lay_first, lay_first + lay_n - 1, (unsigned long)g_pass.tw, (unsigned long)g_pass.th);
    }
    chunk_maybe_split();
    pg_render(pd, (NSUInteger)R.rt.n);
    g_enc = enc_r_begin(pd);
    pg_render_begin(g_enc);
    args_dirty_all();
    g_stat_pass++; g_cnt_pass_d0 = g_stat_draw;
    if (counts_on()) { g_cnt_ext_x = g_cnt_ext_y = 0; g_cnt_ext_clr = pd.depthAttachment.loadAction == MTLLoadActionClear && pd.depthAttachment.texture;
        g_cnt_ext_clr |= pd.stencilAttachment.loadAction == MTLLoadActionClear && pd.stencilAttachment.texture;
        for (int i = 0; i < R.rt.n && i < 8; i++) g_cnt_ext_clr |= pd.colorAttachments[i].texture && pd.colorAttachments[i].loadAction == MTLLoadActionClear; }
    if (enc_label_on()) { id<MTLTexture> lt = pd.colorAttachments[0].texture ?: pd.depthAttachment.texture ?: pd.stencilAttachment.texture; g_el_w = (int)lt.width; g_el_h = (int)lt.height; g_el_draws = 0; g_el_key[0] = 0; }
    return g_enc;
}
// Empty-scissor precheck before opening a pass: the size of the selected level of the first valid target is an upper bound on the minimum bounds of the actual pass.
static void rt_dims(NSUInteger *tw, NSUInteger *th) {
    id<MTLTexture> t0 = nil; NSUInteger level = 0;
    for (int i = 0; i < R.rt.n && i < 8 && !t0; i++) if (R.rt.color[i]) {
        t0 = tex_mtl(R.rt.color[i]); level = R.rt.has_cview[i] && R.rt.cview[i].set_levels ? R.rt.cview[i].base_level : 0;
    }
    if (!t0 && R.rt.depth) { t0 = tex_mtl(R.rt.depth); level = R.rt.has_dview && R.rt.dview.set_levels ? R.rt.dview.base_level : 0; }
    *tw = t0 ? mip_extent(t0.width, level) : 1; *th = t0 ? mip_extent(t0.height, level) : 1;
}
// There are pending clears but no draw in the pass: open a pass once to land the clears
static void rp_flush(void) {
    int pend = R.clear_d || R.clear_s;
    for (int i = 0; i < 8; i++) pend |= R.clear_c[i];
    if (pend && !g_enc && g_cb) rp_begin_ex(1);
    rp_end();
}
static int scissor_full_of(const p_scissor *sc, int has_sc, const tex_t *t, const view_t *v, int has_v) {
    NSUInteger level = has_v && v->set_levels ? v->base_level : 0;
    NSUInteger w = mip_extent(t->d.width, level), h = mip_extent(t->d.target == 0 || t->d.target == 3 ? 1 : t->d.height, level);
    return !has_sc || (sc->x <= 0 && sc->y <= 0 && (int64_t)sc->x + sc->w >= (int64_t)w && (int64_t)sc->y + sc->h >= (int64_t)h);
}
static int scissor_full(const tex_t *t, const view_t *v, int has_v) { return scissor_full_of(&R.sc, R.has_sc, t, v, has_v); }
// Clears a load action cannot do (inside a render pass, a partial channel mask, a partial scissor, a partial stencil mask) are drawn as one
// full-target triangle under the scissor: colour writes only that attachment's masked channels, depth / stencil write the clear value with compare
// Always (stencil Replace under the stencil mask); the triangle is not counted by occlusion queries. NVN clears honour the scissor and the masks.
// Ported from MacNativeGames (ly05010419/MacNativeGames, MIT: clear_quad / clear_ds_quad); our draws set all dynamic state again, the pipeline and
// depth-stencil caches are dropped here
static int clear_scissor(MTLScissorRect *out) {
    NSUInteger tw = g_pass.tw, th = g_pass.th; *out = (MTLScissorRect){0, 0, tw, th};
    if (!R.has_sc) return 1;
    int64_t x0 = MAX(R.sc.x, 0), y0 = MAX(R.sc.y, 0), x1 = MIN((int64_t)R.sc.x + R.sc.w, (int64_t)tw), y1 = MIN((int64_t)R.sc.y + R.sc.h, (int64_t)th);
    if (x1 <= x0 || y1 <= y0) return 0;
    *out = (MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)}; return 1;
}
static void clear_quad_draw(RENC en, id<MTLRenderPipelineState> ps, id<MTLDepthStencilState> ds, uint32_t ref, MTLScissorRect sc) {
    enc_r_pso(en, ps); g_enc_pso = nil; enc_r_dss(en, ds); g_enc_dss = nil;
    if (g_enc_vis) { enc_r_visibility(en, MTLVisibilityResultModeDisabled, 0); g_enc_vis = 0; }
    enc_r_stencil_ref(en, ref, ref); enc_r_viewport(en, (MTLViewport){0, 0, (double)g_pass.tw, (double)g_pass.th, 0, 1}); enc_r_scissor(en, sc);
#ifndef DM_TEST_EXTENT_BROKEN   // (and clear quads not counted)
    if (g_cnt_on > 0) cnt_extent(sc, 0, 0, g_pass.tw, g_pass.th);
#endif
    enc_r_cull(en, MTLCullModeNone); enc_r_fill(en, MTLTriangleFillModeFill); enc_r_depth_bias(en, 0, 0, 0); enc_r_depth_clip(en, YES);
    enc_r_draw_instanced(en, MTLPrimitiveTypeTriangle, 0, 3, 1, 0);
}
static void clear_quad(const p_clear_color *c) {
    if (!(c->mask & 0xf) || c->index < 0 || c->index >= 8) return;
    // A slot attached at two indices is attached once (rt_dup_slot): its clear goes to the index kept (seedds/nxnative 7dde056, MIT; t_nvn 6c3)
    int at = c->index;
    if (at < R.rt.n && rt_dup_slot(&R.rt, at)) for (int j = 0; j < R.rt.n && j < 8; j++) if (j != at && rt_same_sub(&R.rt, at, j) && !rt_dup_slot(&R.rt, j)) { at = j; break; }
    if (g_enc && !g_pass.cfmt[at]) rp_end();
    RENC en = rp_begin(); if (!en) return;
    if (!g_pass.cfmt[at]) { RED_ONCE(75, "partial color clear: attachment %d is not in the render pass (first case)", c->index); return; }
    MTLScissorRect sc; if (!clear_scissor(&sc)) return;
    static NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *cache; static id<MTLDepthStencilState> dss; static id<MTLLibrary> libs[8];
    if (!cache) { cache = [NSMutableDictionary dictionary]; MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new]; dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = NO; dss = [g_dev newDepthStencilStateWithDescriptor:dd]; }
    int i = at;
    if (!libs[i]) {
        NSString *src = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\nconstant float4 cc [[function_constant(0)]];\n"
            "vertex float4 cq_vs(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2 - 1, 0, 1); }\n"
            "struct O { float4 c [[color(%d)]]; };\nfragment O cq_fs() { O o; o.c = cc; return o; }\n", i];
        NSError *e = nil; libs[i] = [g_dev newLibraryWithSource:src options:nil error:&e];
        if (!libs[i]) { RED_ONCE(75, "clear shader: %s", e.localizedDescription.UTF8String); return; }
    }
    NSString *key = [NSString stringWithFormat:@"%d/%x/%u,%u,%u,%u,%u,%u,%u,%u/%u/%u/%u/%a,%a,%a,%a", i, c->mask, g_pass.cfmt[0], g_pass.cfmt[1], g_pass.cfmt[2], g_pass.cfmt[3],
                     g_pass.cfmt[4], g_pass.cfmt[5], g_pass.cfmt[6], g_pass.cfmt[7], g_pass.hd ? g_pass.dfmt : 0, g_pass.hs ? g_pass.sfmt : 0, g_pass.samples, c->rgba[0], c->rgba[1], c->rgba[2], c->rgba[3]];
    id<MTLRenderPipelineState> ps = cache[key];
    if (!ps) {
        MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new]; float v[4] = {c->rgba[0], c->rgba[1], c->rgba[2], c->rgba[3]};
        [cv setConstantValue:v type:MTLDataTypeFloat4 atIndex:0];
        NSError *e = nil; MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [libs[i] newFunctionWithName:@"cq_vs"]; d.fragmentFunction = [libs[i] newFunctionWithName:@"cq_fs" constantValues:cv error:&e];
        for (int k = 0; k < 8; k++) if (g_pass.cfmt[k]) { d.colorAttachments[k].pixelFormat = (MTLPixelFormat)g_pass.cfmt[k]; d.colorAttachments[k].writeMask = MTLColorWriteMaskNone; }
        d.colorAttachments[i].writeMask = (c->mask & 1 ? MTLColorWriteMaskRed : 0) | (c->mask & 2 ? MTLColorWriteMaskGreen : 0) | (c->mask & 4 ? MTLColorWriteMaskBlue : 0) | (c->mask & 8 ? MTLColorWriteMaskAlpha : 0);
        d.depthAttachmentPixelFormat = g_pass.hd ? (MTLPixelFormat)g_pass.dfmt : MTLPixelFormatInvalid; d.stencilAttachmentPixelFormat = g_pass.hs ? (MTLPixelFormat)g_pass.sfmt : MTLPixelFormatInvalid;
        d.rasterSampleCount = g_pass.samples ? g_pass.samples : 1;
        ps = d.fragmentFunction ? [g_dev newRenderPipelineStateWithDescriptor:d error:&e] : nil;
        if (!ps) { RED_ONCE(76, "partial color clear of attachment %d (Metal format %u) not drawn: %s (first case; an integer format needs an integer clear shader)", i, g_pass.cfmt[i], e.localizedDescription.UTF8String); return; }
        cache[key] = ps;
    }
    clear_quad_draw(en, ps, dss, 0, sc);
}
static void clear_ds_quad(const p_clear_ds *c) {
    if (g_enc && ((c->depth_mask && !g_pass.hd) || ((c->stencil_mask & 255) && !g_pass.hs))) rp_end();
    RENC en = rp_begin(); if (!en) return;
    MTLScissorRect sc; if (!clear_scissor(&sc)) return;
    uint32_t dfmt = g_pass.hd ? g_pass.dfmt : 0, sfmt = g_pass.hs ? g_pass.sfmt : 0;
    static NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *pipelines; static NSMutableDictionary<NSNumber *, id<MTLDepthStencilState>> *states; static id<MTLLibrary> lib;
    if (!lib) {
        NSError *e = nil; lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nconstant float depth [[function_constant(0)]];\n"
            "vertex float4 ds_vs(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2 - 1, depth, 1); }\n" options:nil error:&e];
        if (!lib) { RED_ONCE(75, "depth-stencil clear shader: %s", e.localizedDescription.UTF8String); return; }
        pipelines = [NSMutableDictionary dictionary]; states = [NSMutableDictionary dictionary];
    }
    float depth = c->depth_mask && dfmt ? fminf(1, fmaxf(0, c->depth)) : 0;
    NSString *key = [NSString stringWithFormat:@"%u,%u,%u,%u,%u,%u,%u,%u/%u/%u/%u/%a", g_pass.cfmt[0], g_pass.cfmt[1], g_pass.cfmt[2], g_pass.cfmt[3], g_pass.cfmt[4], g_pass.cfmt[5],
                     g_pass.cfmt[6], g_pass.cfmt[7], dfmt, sfmt, g_pass.samples, depth];
    id<MTLRenderPipelineState> ps = pipelines[key];
    if (!ps) {
        MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new]; [cv setConstantValue:&depth type:MTLDataTypeFloat atIndex:0];
        NSError *e = nil; MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"ds_vs" constantValues:cv error:&e];
        for (int k = 0; k < 8; k++) if (g_pass.cfmt[k]) { d.colorAttachments[k].pixelFormat = (MTLPixelFormat)g_pass.cfmt[k]; d.colorAttachments[k].writeMask = MTLColorWriteMaskNone; }
        d.depthAttachmentPixelFormat = (MTLPixelFormat)dfmt; d.stencilAttachmentPixelFormat = (MTLPixelFormat)sfmt; d.rasterSampleCount = g_pass.samples ? g_pass.samples : 1;
        ps = d.vertexFunction ? [g_dev newRenderPipelineStateWithDescriptor:d error:&e] : nil;
        if (!ps) { RED_ONCE(76, "partial depth-stencil clear not drawn: %s (first case)", e.localizedDescription.UTF8String); return; }
        pipelines[key] = ps;
    }
    unsigned sm = sfmt ? c->stencil_mask & 255 : 0, dw = dfmt && c->depth_mask;
    if (!sm && !dw) return;
    NSNumber *dk = @(sm | (dw << 8)); id<MTLDepthStencilState> ds = states[dk];
    if (!ds) {
        MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new]; d.depthCompareFunction = MTLCompareFunctionAlways; d.depthWriteEnabled = dw;
        if (sm) { MTLStencilDescriptor *st = [MTLStencilDescriptor new]; st.stencilCompareFunction = MTLCompareFunctionAlways;
            st.depthStencilPassOperation = MTLStencilOperationReplace; st.writeMask = sm; d.frontFaceStencil = d.backFaceStencil = st; }
        ds = [g_dev newDepthStencilStateWithDescriptor:d]; states[dk] = ds;
    }
    clear_quad_draw(en, ps, ds, (uint32_t)c->stencil, sc);
}


// ================= Shaders / descriptor pool / pipelines / draws =================
static pthread_mutex_t g_rmu = PTHREAD_MUTEX_INITIALIZER;
// ---------- Shader mapping table: Switch shader key (control section + code area, hle_nvn.c shader_key) → PC metallib ----------
static NSMutableDictionary<NSString *, NSString *> *g_shmap;
static NSString *g_shmap_path, *g_msl_dir;
// Shader stage map (gfx/tools/shmap_from_capture.py): Switch shader key → stage; the shaders themselves are translations of the game's own
// Switch shaders built offline by gfx/tools/dmsh_build.py (<key>_b.metallib + reflection JSON)
static void shmap_load(void) {
    if (g_shmap) return;
    const char *e = getenv("DM_NVN_SHMAP");
    if (!e) MDIE("DM_NVN_SHMAP is not set: it names the game's shader stage map (gfx/tools/shmap_from_capture.py)");
    NSString *path = @(e);
    NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!txt) MDIE("cannot read the shader stage map %s", path.UTF8String);
    g_shmap = [NSMutableDictionary dictionary];
    for (NSString *ln in [txt componentsSeparatedByString:@"\n"]) {   // "<key>\t<stage>" per line, # comments
        if (!ln.length || [ln hasPrefix:@"#"]) continue;
        NSArray *c = [ln componentsSeparatedByString:@"\t"];
        if (c.count >= 2) g_shmap[c[0]] = c[1];
    }
    g_shmap_path = path;
    const char *m = getenv("DM_MSL_DIR");
    // Library directory = <DM_MSL_DIR or default cache>/b-<translation chain version>: the version comes from this source tree's dmsh_chain.h (tools/dmsh_chain.py); a host built from an old source tree only accepts libraries of the old version
    g_msl_dir = [NSString stringWithFormat:@"%@/b-%s", m ? @(m) : [@(getenv("DM_ROOT") ?: getenv("HOME")) stringByAppendingPathComponent:getenv("DM_ROOT") ? @"build/cache/metal_shader_cache" : @"dm-work/build/cache/metal_shader_cache"], DMSH_CHAIN];
    if (![NSFileManager.defaultManager fileExistsAtPath:g_msl_dir]) MLOG("[red] shader library directory %s does not exist: translation chain version %s of this source tree has not been packaged yet (gfx/tools/dmsh_build.py)", g_msl_dir.UTF8String, DMSH_CHAIN);
    NSString *cp = [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"c1_full.tsv"];   // Same directory as the mapping table (Mac: gfx/nvn; iOS: dm/ inside the App, copied along by run.sh)
    NSString *ct = cp ? [NSString stringWithContentsOfFile:cp encoding:NSUTF8StringEncoding error:nil] : nil;
    NSString *head = ct ? [[ct componentsSeparatedByString:@"\n"] firstObject] : nil;
    NSString *want = [NSString stringWithFormat:@"# chain b-%s", DMSH_CHAIN];
    if (!head || ![head hasPrefix:want]) {
        MLOG("[red] c1_full.tsv list is stale or missing, every c1 gets an exclusive 64 KiB");
    } else {
        g_c1_full_valid = 1; g_c1_full = [NSMutableSet set];
        for (NSString *line in [ct componentsSeparatedByString:@"\n"]) if (line.length && ![line hasPrefix:@"#"]) [g_c1_full addObject:[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    }
    MLOG("shader route B (translated from the original Switch shaders): map has %lu entries (%s), metallib directory %s", (unsigned long)g_shmap.count, path.UTF8String, g_msl_dir.UTF8String);
    warm_start();
}

@interface NvShader : NSObject { @public id<MTLFunction> fn; nvn_refl rf; id<MTLArgumentEncoder> ae; NSUInteger arg_len; int stage, range_ro; char key[24]; id<MTLBuffer> c1buf; uint64_t c1_gpu; size_t c1off;
    id<MTLLibrary> vi_lib; NSString *vi_entry; uint32_t vi_mask; NSMutableDictionary<NSNumber *, id<MTLFunction>> *vi_fns;   // integer vertex input variant (dmsh_build.py vi_variant): locations that can be specialized
    // The argument buffer encoded last time
    id<MTLBuffer> ab_buf; uint64_t ab_gpu; size_t ab_off; uint64_t ab_pass;   // ab_pass: serial of the render pass that encoded this argument block - reused only within the same pass (the arena holding a block from another pass / another submission may already have been reclaimed and rewritten)
    id<MTLLibrary> bflib; int bflib_tried; NSMutableDictionary<NSString *, id<MTLFunction>> *bffn;   // bflib: readable-tile version <key>_bf (merge B step 2)
    id<MTLLibrary> alib; NSMutableDictionary<NSNumber *, id<MTLFunction>> *afn; } @end   // alib: a fragment shader with the alpha test epilogue (dmsh_build.py alpha_test); afn: its specializations
@implementation NvShader @end
#include "nvn_pso_skey.h"
@interface NvProg : NSObject { @public NvShader *sh[6]; int sum_ok, sum_img, sum_imgw; uint32_t sum_cmask; } @end   // sum_*: udc_note_draw's per-program summary
@implementation NvProg @end
// What udc_note_draw needs of a program, worked out once (upstream d2r-mobile 44a6770 caches it per program): any image binding, any writable one,
// the pixel shader's colour outputs. Its shaders are fixed once the program is built, so the summary never goes stale
static void prog_summary(NvProg *pr) {
    if (pr->sum_ok) return;
    for (int st = 0; st < 6; st++) { __unsafe_unretained NvShader *sh = pr->sh[st]; if (!sh) continue;
        if (st == 1) pr->sum_cmask = sh->rf.color_mask;
        for (int i = 0; i < sh->rf.nb; i++) if (sh->rf.b[i].kind == NVN_RB_IMG) { pr->sum_img = 1; if (sh->rf.b[i].rw) pr->sum_imgw = 1; } }
    pr->sum_ok = 1;
}
// Warm-up entry: built in the background, waiting to be taken by the submit thread. vs / fs are strong references (in pso they are only raw pointers, and the background dictionary is released when the task ends)
@interface WarmItem : NSObject { @public int kind; NSString *key, *vs_key, *fs_key; NvShader *shader, *vs, *fs; pso_key pso; id<MTLFunction> fsfn; id object; } @end
@implementation WarmItem @end
static NSMutableDictionary<NSString *, NvShader *> *g_shcache;

static void c1_store(NvShader *o) {
    size_t len = o->rf.c1_len;
    NSString *guardKey = [NSString stringWithUTF8String:o->key];
    if ([guardKey hasSuffix:@"_b"]) guardKey = [guardKey substringToIndex:guardKey.length - 2];
    os_unfair_lock_lock(&g_c1_lock);   // Both the warm-up thread and the submit thread load shaders
    if (!g_c1_full_valid || [g_c1_full containsObject:guardKey]) {   // Runtime index not proven bounded: exclusive 64 KiB of all zeros (same as the original implementation)
        o->c1buf = [g_dev newBufferWithLength:C1_DECL_SIZE options:MTLResourceStorageModeShared]; o->c1_gpu = o->c1buf.gpuAddress;
        if (!o->c1buf) { os_unfair_lock_unlock(&g_c1_lock); MDIE("c1 exclusive buffer allocation failed"); }
        res_add(o->c1buf);
        memset(o->c1buf.contents, 0, C1_DECL_SIZE); memcpy(o->c1buf.contents, o->rf.c1, len);
        g_c1_alloc_bytes += C1_DECL_SIZE; g_c1_data_bytes += len; g_c1_count++; g_c1_exclusive++;
        os_unfair_lock_unlock(&g_c1_lock);
        return;
    }
    size_t need = (len + 255u) & ~((size_t)255u);
    if (!g_c1_banks) g_c1_banks = [NSMutableArray array];
    if (!g_c1_banks.count || g_c1_bank_off + need + 256u + C1_DECL_SIZE > C1_BANK_SIZE) {
        id<MTLBuffer> b = [g_dev newBufferWithLength:C1_BANK_SIZE options:MTLResourceStorageModeShared];
        if (!b) { os_unfair_lock_unlock(&g_c1_lock); MDIE("c1 buffer block allocation failed"); }
        res_add(b);
        memset(b.contents, 0, C1_BANK_SIZE);
        [g_c1_banks addObject:b];
        g_c1_bank_off = 0;
        g_c1_alloc_bytes += C1_BANK_SIZE;
    }
    id<MTLBuffer> b = g_c1_banks.lastObject;
    size_t off = g_c1_bank_off;
    memcpy((uint8_t *)b.contents + off, o->rf.c1, len);
    g_c1_bank_off += need + 256u;
    g_c1_data_bytes += len;
    g_c1_count++;
    o->c1buf = b;
    o->c1_gpu = b.gpuAddress;
    o->c1off = off;
    os_unfair_lock_unlock(&g_c1_lock);
}

static NSMutableArray<WarmItem *> *g_warm_items;
static os_unfair_lock g_warm_lock = OS_UNFAIR_LOCK_INIT;
static _Atomic int g_warm_ready;
static int g_warm_started;
static uint64_t g_warm_t0;
static _Atomic int g_warm_running;   // Background warm-up has not finished yet (the loading screen on entering a run waits a little longer based on this, see mtl_warm_wait)
static uint64_t g_warm_shaders, g_warm_rps, g_warm_cps, g_warm_skip_fz;
static uint64_t g_warm_claim_shaders, g_warm_claim_rps, g_warm_claim_cps;
static id<MTLFunction> bf_fn(NvShader *fs, const int *fx, uint8_t fbmask, const uint8_t *lmap);
static id<MTLFunction> alpha_plain(id<MTLLibrary> lib, NSString *entry);
static int rt_range_bindings_ro(NSDictionary *j);
static FILE *g_pso_record; static int g_pso_record_checked;
static FILE *pso_record_file(void) {
    if (g_pso_record_checked) return g_pso_record;
    g_pso_record_checked = 1;
    const char *path = getenv("DM_PSO_RECORD");
    if (path && *path) g_pso_record = fopen(path, "a");
    return g_pso_record;
}
static void pso_record(const char *fmt, ...) {
    FILE *f = pso_record_file();
    if (!f) return;
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap); fflush(f);
}
// User manifest: shaders / pipelines created synchronously on the submit thread while running on this machine, warmed up at the next launch together with the seed manifest.
// Path = DM_PSO_USER, or pso_user.tsv under the parent of the save directory (DM_SAVE, Documents/save on iOS); tests use a fresh save copy per run, so they do not pollute each other
static NSString *pso_user_path(void) {
    const char *u = getenv("DM_PSO_USER"), *save = getenv("DM_SAVE");
    if (u && *u) return @(u);
    return save && *save ? [[@(save) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"pso_user.tsv"] : nil;
}
static FILE *g_pso_user; static int g_pso_user_checked;
static NSMutableSet<NSString *> *g_pso_user_seen;
static FILE *pso_user_file(void) {
    if (g_pso_user_checked) return g_pso_user;
    g_pso_user_checked = 1;
    NSString *path = pso_user_path();
    if (path) g_pso_user = fopen(path.fileSystemRepresentation, "a");
    return g_pso_user;
}
static void pso_user_record(const char *fmt, ...) {
    FILE *f = pso_user_file();
    if (!f) return;
    char line[8192]; va_list ap; va_start(ap, fmt); vsnprintf(line, sizeof line, fmt, ap); va_end(ap);
    if (!g_pso_user_seen) {
        g_pso_user_seen = [NSMutableSet set];
        NSString *seed = g_shmap_path ? [g_shmap_path.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"pso_manifest.tsv"] : nil;
        NSMutableArray<NSString *> *paths = [NSMutableArray array]; if (seed) [paths addObject:seed]; NSString *user = pso_user_path(); if (user) [paths addObject:user];
        for (NSString *path in paths) { NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            for (NSString *old in [txt componentsSeparatedByString:@"\n"]) if (old.length && ![old hasPrefix:@"#"]) [g_pso_user_seen addObject:old]; }
    }
    size_t ll = strlen(line); NSString *s = [[NSString alloc] initWithBytes:line length:ll && line[ll - 1] == '\n' ? ll - 1 : ll encoding:NSUTF8StringEncoding];   // Compared with the manifest file line by line (without the newline)
    if (!s || [g_pso_user_seen containsObject:s]) return;
    [g_pso_user_seen addObject:s]; fputs(line, f); fflush(f);
}
// Build the library from a .metallib file without permanently occupying a file descriptor: newLibraryWithURL keeps that file open for as long as the library object lives (one per game shader - of the 258 descriptors the iOS app permanently holds in a run, 213 are these,
// while the default soft limit of an iOS process is 256; new shaders created in other acts raise it further). Here the file is mapped into memory and closed immediately, and the library is built from the in-memory data; the mapping is released when the library's data object is freed
static id<MTLLibrary> lib_from_file(NSString *path, NSError **err) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY); struct stat st;
    if (fd < 0 || fstat(fd, &st) || st.st_size <= 0) { if (fd >= 0) close(fd); if (err) *err = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"cannot open %@", path]}]; return nil; }
    size_t len = (size_t)st.st_size; void *m = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0); close(fd);
    if (m == MAP_FAILED) { if (err) *err = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"mmap failed %@", path]}]; return nil; }
    dispatch_data_t d = dispatch_data_create(m, len, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ munmap(m, len); });
    return [g_dev newLibraryWithData:d error:err];
}
static NvShader *shader_load(NSString *pc, int stage) {
    NSError *e = nil;
    NSString *lp = [NSString stringWithFormat:@"%@/%@.metallib", g_msl_dir, pc];
    id<MTLLibrary> lib = lib_from_file(lp, &e);
    NSData *jd = [NSData dataWithContentsOfFile:[NSString stringWithFormat:@"%@/%@.json", g_msl_dir, pc]];
    NSDictionary *j = jd ? [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil] : nil;
    if (!lib || !j) { MLOG("[red] failed to load shader %s: %s", pc.UTF8String, e ? e.localizedDescription.UTF8String : "no reflection json"); return nil; }
    if (![j[@"chain"] isEqual:@DMSH_CHAIN]) { MLOG("[red] shader %s translation chain version %s does not match the %s expected by this host", pc.UTF8String, [[j[@"chain"] description] UTF8String], DMSH_CHAIN); return nil; }
    NvShader *o = [NvShader new];
    char err[160];
    if (nvn_refl_from_json(j, &o->rf, err, sizeof err)) { MLOG("[red] shader %s reflection conversion failed: %s", pc.UTF8String, err); return nil; }
    if (rt_range_on()) o->range_ro=rt_range_bindings_ro(j);
    o->fn = [lib newFunctionWithName:j[@"entry"]]; o->stage = stage; strlcpy(o->key, pc.UTF8String, sizeof o->key);
    if (stage == 1 && [j[@"alpha_test"] boolValue]) { o->alib = lib; o->fn = alpha_plain(lib, j[@"entry"]); }   // the alpha test epilogue: specialized with ALWAYS (alpha_fn)
    if (!o->fn) { MLOG("[red] shader %s: no function %s", pc.UTF8String, [[j[@"entry"] description] UTF8String]); return nil; }
    if ([j[@"vi_entry"] isKindOfClass:NSString.class]) { o->vi_lib = lib; o->vi_entry = j[@"vi_entry"]; for (NSNumber *l in j[@"vi_int"]) if (l.intValue >= 0 && l.intValue < 16) o->vi_mask |= 1u << l.intValue; }
    if (o->rf.nb) {
        o->ae = [o->fn newArgumentEncoderWithBufferIndex:o->rf.abi];
        int max_aid = -1;
        for (int i = 0; i < o->rf.nb; i++) max_aid = MAX(max_aid, o->rf.b[i].aid);
        o->arg_len = o->ae.encodedLength;
        if (o->arg_len != (NSUInteger)(8 * (max_aid + 1)) || (o->arg_len & 7))
            MDIE("shader %s argument buffer layout anomaly: encodedLength=%lu maxAid=%d", o->key, (unsigned long)o->arg_len, max_aid);
    }
    if (o->rf.has_c1) c1_store(o);
    return o;
}

static int stage_of(NSString *st) {   // NVN shader stage of a shader map entry
    if ([st isEqualToString:@"vs"]) return 0; if ([st isEqualToString:@"ps"]) return 1; if ([st isEqualToString:@"cs"]) return 5;
    if ([st isEqualToString:@"hs"]) return 3; if ([st isEqualToString:@"ds"]) return 4; return -1;
}
#define NVN_RT_RANGE_RO_IMPL 1
// Private continuation accepts only B reflection that is explicitly RO; a missing rw on sbuf does not let the default 0 count as proof; does not change the existing reflection / translation chain.
static int rt_range_bindings_ro(NSDictionary *j) {
    if (![j[@"route"] isEqual:@"B"] || ![j[@"bindings"] isKindOfClass:[NSArray class]] ||
        ![j[@"drv_reads"] isKindOfClass:[NSDictionary class]] || [j[@"drv_reads"] count]) return 0;
    for (NSDictionary *b in j[@"bindings"]) {
        if (![b isKindOfClass:[NSDictionary class]] || ![b[@"kind"] isKindOfClass:[NSString class]] || ![b[@"msl_type"] isKindOfClass:[NSString class]]) return 0;
        NSString *k=b[@"kind"], *t=b[@"msl_type"];
        if (b[@"rw"] && (![b[@"rw"] isKindOfClass:[NSNumber class]] || [b[@"rw"] boolValue])) return 0;
        if ([k isEqual:@"cbuf"] || [k isEqual:@"c1"]) { if (![t hasPrefix:@"constant "]) return 0; }
        else if ([k isEqual:@"sbuf"]) { if (![b[@"rw"] isKindOfClass:[NSNumber class]] || [b[@"rw"] boolValue] || ![t hasPrefix:@"const device "]) return 0; }
        else if ([k isEqual:@"samp"] || [k isEqual:@"sampt"]) { if (![t isEqual:@"sampler"]) return 0; }
        else if ([k isEqual:@"tex"] || [k isEqual:@"tbuf"]) {
            if (![t hasPrefix:@"texture"] || ([t containsString:@"access::"] && ![t containsString:@"access::sample>"] && ![t containsString:@"access::read>"])) return 0; }
        else return 0;
    }
    return 1;
}
static int rt_range_pr_ro(NvProg *p) {
    if (!p || !p->sh[0] || !p->sh[1]) return 0;
    for (int k=0;k<6;k++) if (p->sh[k] && (k>1 || p->sh[k]->stage != k || !p->sh[k]->range_ro || p->sh[k]->rf.drv_read[0] || p->sh[k]->rf.drv_read[2])) return 0;
    return 1;
}
static NvShader *shader_get(NSString *pc, int stage) {
    if (!g_shcache) g_shcache = [NSMutableDictionary dictionary];
    NvShader *o = g_shcache[pc];
    if (o) return o;
    uint64_t bt = bp_now(); o = shader_load(pc, stage);
    if (!o) return nil;
    g_shcache[pc] = o;
    pso_record("S\t%s\t%d\n", pc.UTF8String, stage);
    pso_user_record("S\t%s\t%d\n", pc.UTF8String, stage);
    g_bp_lib_n++; g_bp_lib_ns += bp_now() - bt;
    return o;
}
static __unsafe_unretained NvProg *prog_get(const prog_t *cp) {   // Called only on the submit thread
    prog_t *p = (prog_t *)cp;
    static const prog_t *lp; static uint64_t lser, lgen; static NvProg *lpr;   // Last result: same object, same serial and unchanged serial table means it is used directly
    uint64_t gen = atomic_load_explicit(&g_ser_gen, memory_order_acquire);
    if (p == lp && p->serial == lser && lpr && (gen == lgen || ser_unaffected(lgen, gen, lser))) { lgen = gen; return lpr; }   // steps for other serials leave it
    __unsafe_unretained NvProg *have = p->serial ? serial_get(p->serial) : nil;
    if (have) { lp = p; lser = p->serial; lgen = gen; lpr = have; return have; }
    shmap_load();
    NvProg *o = [NvProg new];
    for (unsigned i = 0; i < p->nstage; i++) {
        const uint8_t *md = p->key[i];   // shader key computed at SetShaders (the game may already have reclaimed the control section memory by now)
        NSString *k = [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x", md[0], md[1], md[2], md[3], md[4], md[5], md[6], md[7]];
        NSString *zh = g_shmap[k];
        if (!zh) { MLOG("[red] shader %s is not in the shader map", k.UTF8String); continue; }
        int st = stage_of(zh);
        NvShader *sh = st >= 0 ? shader_get([k stringByAppendingString:@"_b"], st) : nil;
        if (sh) o->sh[st] = sh; else MLOG("[red] shader %s (%s) failed to load: run gfx/tools/dmsh_build.py to package first", k.UTF8String, zh.UTF8String);
    }
    if (p->serial) serial_put(p->serial, o);
    return o;
}
void mtl_prog_release(prog_t *p) { @autoreleasepool { if (p->serial) serial_del(p->serial); } }

// ---------- Descriptor pool: texture ID / sampler ID → object ----------
// At registration the whole texture object is snapshotted (NVN semantics: the descriptor has been written into the pool); view: the MTLTexture for that ID (a view or the base texture, held via CFBridgingRetain) and the serial-table / guest-write generations at the time it was obtained
// fin: the texture this entry names was released after nvnTextureFinalize (fin_drain) while the ID stayed registered, at submission fin_sub
typedef struct { tex_t t; int ok, fin; view_t v; int has_v; void *view; uint64_t view_id, view_rid, view_ser, view_dirty, fin_sub, live_gen; int view_kind;
                 void *alt, *alt_of; uint64_t alt_rid; uint8_t alt_type; } treg_t;   // alt: a view of another texture type for shaders that declare one (tex_fit), built from the view alt_of
static void treg_alt_drop(treg_t *r) { if (r->alt) { defer_obj_unref((__bridge id)r->alt); CFRelease(r->alt); r->alt = r->alt_of = NULL; r->alt_rid = 0; } }
static treg_t *g_treg; static int g_ntreg; static uint64_t g_treg_same;   // g_treg_same: identical registrations skipped
// Lock-free copy of texture ID → serial (the replay hot path only needs the serial: store lookahead index, binding set of the clear-only hoist): texture IDs are 20 bits, fixed 1M entries (BSS, only touched pages are used),
// release write at registration, relaxed atomic read on the reader side, without entering g_rmu (the former h_ser locked and unlocked on every lookup, thousands of times per frame in the camp)
static _Atomic uint64_t g_tser[1 << 20];
static samp_par *g_sreg; static uint8_t *g_sreg_ok; static void **g_sview; static uint64_t *g_srid; static int g_nsreg;   // g_sview: sampler ID → MTLSamplerState (retained)
void mtl_reg_tex(int tid, const tex_t *t, const view_t *v) { @autoreleasepool {
    int id_ = tid; if (id_ < 0) return;
    pthread_mutex_lock(&g_rmu);
    if (id_ >= g_ntreg) { int n = id_ + 1024; g_treg = realloc(g_treg, n * sizeof *g_treg); memset(g_treg + g_ntreg, 0, (n - g_ntreg) * sizeof *g_treg); g_ntreg = n; }
    // The same descriptor written into the slot again (games do it all the time) changes nothing: the slot keeps its view and no argument block has to
    // be encoded again for it (g_reg_gen; MacNativeGames, MIT). A slot whose texture was released (fin) takes it as before
    { treg_t *r = &g_treg[id_];
      if (t && r->ok && !r->fin && r->has_v == (v != NULL) && !memcmp(&r->t, t, sizeof *t) && (!v || !memcmp(&r->v, v, sizeof *v))) { g_treg_same++; pthread_mutex_unlock(&g_rmu); return; } }
    g_reg_gen++;
    if (g_treg[id_].view) { defer_obj_unref((__bridge id)g_treg[id_].view); CFRelease(g_treg[id_].view); g_treg[id_].view = NULL; g_treg[id_].view_id = g_treg[id_].view_rid = 0; }
    treg_alt_drop(&g_treg[id_]);
    // A registration without a view must not keep the slot's previous view: tex_by_id reads the view's fields whenever the texture has a swizzle
    // (MacNativeGames found a depth texture sampled through a stale BC3 view; ly05010419/MacNativeGames, MIT)
    g_treg[id_].ok = t != NULL; g_treg[id_].fin = 0; if (t) g_treg[id_].t = *t; g_treg[id_].has_v = v != NULL;
    if (v) g_treg[id_].v = *v; else memset(&g_treg[id_].v, 0, sizeof g_treg[id_].v);
    if (id_ < (1 << 20)) atomic_store_explicit(&g_tser[id_], t ? t->serial : 0, memory_order_release);
    pthread_mutex_unlock(&g_rmu);
} }
// The texture of a serial was finalized: drop the views that texture IDs still cache for it. A cached view is a strong reference (a view also keeps its
// base texture), and the game need not register those IDs again or use them before it exits: a finalized render target stayed allocated until then
// (Mac, a trial scene: ~800 MB of retired render targets within three minutes. An iPhone session ended without a crash report near its memory limit)
static void treg_drop_views(const uint64_t *serials, int n) {   // fin_drain, n <= 64: the serials go into a set of 128 (serial 0 marks an empty place)
    uint64_t set[128] = {0}, lo = UINT64_MAX, hi = 0;
    for (int k = 0; k < n && k < 64; k++) {
        uint64_t s = serials[k]; if (!s) continue;
        unsigned h = (unsigned)((s * 0x9E3779B97F4A7C15ull) >> 57); while (set[h] && set[h] != s) h = (h + 1) & 127;
        set[h] = s; lo = MIN(lo, s); hi = MAX(hi, s);
    }
    if (lo > hi) return;
    pthread_mutex_lock(&g_rmu);
    for (int i = 1; i < g_ntreg && i < (1 << 20); i++) {
        uint64_t s = atomic_load_explicit(&g_tser[i], memory_order_relaxed);
        if (s < lo || s > hi) continue;
        unsigned h = (unsigned)((s * 0x9E3779B97F4A7C15ull) >> 57); while (set[h] && set[h] != s) h = (h + 1) & 127;
        if (set[h] != s || !g_treg[i].ok) continue;
        g_treg[i].fin = 1; g_treg[i].fin_sub = g_sub_serial;
        if (g_treg[i].view) { defer_obj_unref((__bridge id)g_treg[i].view); CFRelease(g_treg[i].view); g_treg[i].view = NULL; g_treg[i].view_id = g_treg[i].view_rid = 0; }
        treg_alt_drop(&g_treg[i]);
    }
    pthread_mutex_unlock(&g_rmu);
}
void mtl_reg_samp(int sid, const samp_par *sp) { @autoreleasepool {
    int id_ = sid; if (id_ < 0) return;
    pthread_mutex_lock(&g_rmu);
    if (id_ >= g_nsreg) { int n = id_ + 256; g_sreg = realloc(g_sreg, n * sizeof *g_sreg); g_sreg_ok = realloc(g_sreg_ok, n); g_sview = realloc(g_sview, n * sizeof *g_sview); g_srid = realloc(g_srid, n * sizeof *g_srid);
        memset(g_sreg_ok + g_nsreg, 0, n - g_nsreg); memset(g_sview + g_nsreg, 0, (n - g_nsreg) * sizeof *g_sview); memset(g_srid + g_nsreg, 0, (n - g_nsreg) * sizeof *g_srid); g_nsreg = n; }
    if (g_sview[id_]) { CFRelease(g_sview[id_]); g_sview[id_] = NULL; g_srid[id_] = 0; }
    g_reg_gen++;
    g_sreg[id_] = *sp; g_sreg_ok[id_] = 1;
    pthread_mutex_unlock(&g_rmu);
} }
static MTLTextureType ttype(int target, int fallback) {
    switch (target) { case 0: return MTLTextureType2D; case 1: case 7: return MTLTextureType2D; case 2: return MTLTextureType3D;   // 1D as one-row 2D (see where textures are created)
        case 3: return MTLTextureType2DArray; case 4: return MTLTextureType2DArray; case 5: return MTLTextureType2DMultisample;
        case 6: return MTLTextureType2DMultisampleArray; case 8: return MTLTextureTypeCube; case 9: return MTLTextureTypeCubeArray; }
    return (MTLTextureType)fallback;
}
// Out-of-pool texture ID = empty slot: the game itself uses GetSeparateTextureHandle(0xFFFFF) to get a handle and bind it to unused slots (measured call site main+0x1746820,
// texture pool capacity 15256) and never registers that ID. Read 0 per D3D / empty-slot semantics (the same all-zero dummy textures as unbound), no failure; unregistered IDs inside the pool are still reported a failure
// c[2] handle table layout of the game's shaders (game.json nvn_c2; hle_nvn.c sets it at nvnDeviceInitialize, the graphics unit tests keep manosaba's)
static struct { int tex, ntex, samp, nsamp; } g_c2 = {0x168, 128, 0x568, 128};
void mtl_set_c2_layout(int tex, int ntex, int samp, int nsamp) {
    if (tex < 0 || samp < 0 || tex + 8 * ntex > 0xA00 || samp + 8 * nsamp > 0xA00) MDIE("c[2] layout tex %#x x %d / samp %#x x %d does not fit the 0xA00-byte bank", tex, ntex, samp, nsamp);
    g_c2.tex = tex; g_c2.ntex = ntex; g_c2.samp = samp; g_c2.nsamp = nsamp;
}
int mtl_c2_tex_base(void) { return g_c2.tex; }
// Depth convention the vertex shaders must have been built for (game.json depth_mode; 1 = near_is_zero, manosaba's, until hle_nvn.c sets it)
static int g_depth_mode = 1;
void mtl_set_depth_mode(int m) { g_depth_mode = m; }
const char *mtl_depth_mode_name(void) { return g_depth_mode ? "near_is_zero" : "near_is_minus_w"; }
int mtl_c2_samp_base(void) { return g_c2.samp; }
static int g_tpool_n; static uint64_t g_stat_tex_oob;
void mtl_set_tex_pool_n(int n) { g_tpool_n = n; }
// What a texture ID's cached view was checked against: kind 1 = its MTLTexture follows guest memory (packaged, or CPU-filled: tex_mtl checks it once per
// submission), so the view holds within the submission; kind 0 = it does not (GPU-only, buffer and linear textures), so guest writes never touch it.
// The view used to be dropped at every guest write anywhere (MacNativeGames treg_stamp, MIT; written anew here)
static inline int treg_kind(const tex_t *t) { return (t->has_layout && t->mem) || tex_cpu_candidate(t); }
static inline uint64_t treg_stamp(int kind) { return !kind ? 0 : check_once() ? g_sub_serial : nvn_dirty_now(); }
static id<MTLTexture> tex_by_id(int tid) {   // Caller holds g_rmu
    if (g_tpool_n && tid >= g_tpool_n) { if (!g_stat_tex_oob++) MLOG("texture ID %d outside the pool (pool capacity %d) treated as an empty slot: reads 0", tid, g_tpool_n); return nil; }
    if (tid < 0 || tid >= g_ntreg || !g_treg[tid].ok) { RED_ONCE(10, "texture ID %d not registered", tid); return nil; }
    treg_t *rp = &g_treg[tid];
    uint64_t fg = atomic_load_explicit(&g_fin_gen, memory_order_acquire);
    if (rp->live_gen != fg || rp->fin) {   // a texture was finalized since this entry was checked: if it was this entry's, follow its storage to the live one
        tex_t live;
        if (live_follow(&rp->t, rp->fin, &live)) {
            uint64_t n = atomic_fetch_add(&g_live_follows, 1) + 1;
            if (n <= 4 || !(n % 10000)) MLOG("texture ID %d follows its storage from finalized serial %llu to serial %llu (%llu so far)", tid, (unsigned long long)rp->t.serial, (unsigned long long)live.serial, (unsigned long long)n);
            if (rp->view) { defer_obj_unref((__bridge id)rp->view); CFRelease(rp->view); rp->view = NULL; rp->view_id = rp->view_rid = 0; }
            treg_alt_drop(rp);
            rp->t = live; rp->fin = 0; g_reg_gen++;
            if (tid < (1 << 20)) atomic_store_explicit(&g_tser[tid], live.serial, memory_order_release);
        }
        rp->live_gen = fg;
    }
    // Take the generations first and then look up: if a change happens in between, the next time must take the slow path. Generation steps all for other
    // serials leave the view valid; and only a texture whose MTLTexture follows guest memory looks at guest writes, once per submission (treg_stamp)
    // (the kind is that of rp->t, fixed while the view is: a new registration or a storage follow drops the view)
    uint64_t sg = atomic_load_explicit(&g_ser_gen, memory_order_acquire);
    if (rp->view && rp->view_dirty == treg_stamp(rp->view_kind) && (rp->view_ser == sg || ser_unaffected(rp->view_ser, sg, rp->t.serial))) { rp->view_ser = sg; return (__bridge id<MTLTexture>)rp->view; }
    int kind = treg_kind(&rp->t); uint64_t dg = treg_stamp(kind);
    id<MTLTexture> v = (__bridge id<MTLTexture>)rp->view;
    if (v) {   // The serial table or guest memory has changed: check whether the base texture was re-uploaded and replaced; if so the view is invalidated
        id<MTLTexture> cur = tex_mtl(&rp->t);
        if (cur == v || v.parentTexture == cur) { rp->view_ser = sg; rp->view_dirty = dg; rp->view_kind = kind; return v; }
        defer_obj_unref(v); CFRelease(rp->view); rp->view = NULL; rp->view_rid = 0; v = nil; treg_alt_drop(rp);
    }
    // The game uses an ID whose texture was released after its finalize and grace period: its descriptor still names that storage, so the texture is
    // created again from the snapshot (a render target comes back blank) and queued for release again, so it does not stay forever
    if (rp->fin) {
        // Tears of the Kingdom's loading screen samples two BC4 textures through their IDs after finalizing them: on the console the descriptor still
        // reads their storage, and so does the texture made again here when that storage is its content (CPU-filled) or the storage's shared texture
        // still holds it (stor_*); only a rendered texture with nothing kept comes back blank (red). It stays RECREATE_GRACE submissions this time:
        // released after FIN_GRACE it was made again every 16 submissions while the loading screen lasted
        rp->fin = 0; fin_queue_due(rp->t.serial, g_sub_serial + RECREATE_GRACE);
        stor_key sk; int kept = tex_membacked(&rp->t);
        if (!kept && stor_key_of(&rp->t, &sk)) { pthread_mutex_lock(&g_smu); kept = nvn_hm_get(&g_stor, &sk) != NULL; pthread_mutex_unlock(&g_smu); }
        if (kept) { uint64_t n_kept = ++g_late_kept; if (n_kept <= 4 || !(n_kept % 64)) MLOG("texture ID %d used %llu submissions after its texture (serial %llu, %ux%u format %#x) was released after nvnTextureFinalize: made again from its storage (%llu so far)",
            tid, (unsigned long long)(g_sub_serial - rp->fin_sub), (unsigned long long)rp->t.serial, rp->t.d.width, rp->t.d.height, rp->t.d.format, (unsigned long long)n_kept); }
        else { uint64_t n_late = ++g_late_blank; if (n_late <= 8 || !(n_late % 64)) MLOG("[red] texture ID %d used %llu submissions after its texture (serial %llu, %ux%u format %#x) was released after nvnTextureFinalize: created again blank (%llu so far)",
            tid, (unsigned long long)(g_sub_serial - rp->fin_sub), (unsigned long long)rp->t.serial, rp->t.d.width, rp->t.d.height, rp->t.d.format, (unsigned long long)n_late); }
    }
    treg_t r = *rp;
    if (!r.has_v) memset(&r.v, 0, sizeof r.v);   // only a registered view may change format, levels, layers or target (MacNativeGames)
    id<MTLTexture> base = tex_mtl(&rp->t);
    if (!base) return nil;
    v = base;
    // Swizzle: the view's when it set one (it replaces the texture's, even as the identity), else the texture's; built as a view with swizzle (NVN and
    // Metal swizzle enums have the same numeric values)
    uint8_t esw[4] = {r.t.d.swz[0], r.t.d.swz[1], r.t.d.swz[2], r.t.d.swz[3]}; int tswz = r.t.d.swz_set;
    if (r.has_v && r.v.set_swz) { esw[0] = r.v.swz_r; esw[1] = r.v.swz_g; esw[2] = r.v.swz_b; esw[3] = r.v.swz_a; tswz = !(esw[0] == 2 && esw[1] == 3 && esw[2] == 4 && esw[3] == 5); }
    if ((r.has_v && (r.v.set_format || r.v.set_levels || r.v.set_layers || r.v.set_target || r.v.set_swz)) || tswz) {
        uint32_t pf = (uint32_t)base.pixelFormat; uint8_t swz[4];
        if (r.v.set_format && !(nvn_fmt_to_mtl(r.v.format, &pf, swz) && pf)) pf = (uint32_t)base.pixelFormat;
        { uint32_t upf; int ubpp; if (r.v.set_format && bc_unpack(r.v.format, &upf, &ubpp)) pf = upf; }   // No BC: a BC view is switched to the decompressed format just like the base texture
        // Metal makes format views only within one size class, never across compressed ↔ uncompressed or depth / stencil ↔ colour except sRGB pairs;
        // anything else aborts the process in texture view validation. Such a pool entry is sampled in the base format, reported once with its formats
        if (pf != (uint32_t)base.pixelFormat && tex_need_pfv(base.pixelFormat, (MTLPixelFormat)pf)) {
            int bw, bh, vbw, vbh, bb = nvn_fmt_bpb(r.t.d.format, &bw, &bh), vb = nvn_fmt_bpb(r.v.format, &vbw, &vbh);
            if (mtl_fmt_block(base.pixelFormat) || mtl_fmt_block((MTLPixelFormat)pf) || pf_is_depth_stencil(base.pixelFormat) || pf_is_depth_stencil((MTLPixelFormat)pf) || !bb || bb != vb || bw != 1 || bh != 1 || vbw != 1 || vbh != 1) {
                RED_ONCE(72, "texture ID %d: view format %#x (Metal %u) is not a valid Metal view of texture format %#x (Metal %lu, %ux%u, serial %llu): sampled in the texture's format (first case)",
                         tid, r.v.format, pf, r.t.d.format, (unsigned long)base.pixelFormat, r.t.d.width, r.t.d.height, (unsigned long long)r.t.serial);
                pf = (uint32_t)base.pixelFormat;
            }
        }
        if (r.v.set_format && tex_need_pfv(base.pixelFormat, (MTLPixelFormat)pf) && !(base.usage & MTLTextureUsagePixelFormatView)) {
            base = tex_upgrade_pfv(&rp->t, base, (MTLPixelFormat)pf);
            sg = atomic_load_explicit(&g_ser_gen, memory_order_acquire);
        }
        NSUInteger l0 = r.v.set_levels ? r.v.base_level : 0, nl = r.v.set_levels && r.v.nlevels ? r.v.nlevels : base.mipmapLevelCount - l0;
        NSUInteger s0 = r.v.set_layers ? r.v.min_layer : 0;
        NSUInteger ns = base.textureType == MTLTextureType3D ? 1 : (r.v.set_layers && r.v.nlayers ? r.v.nlayers : base.arrayLength * (base.textureType == MTLTextureTypeCube || base.textureType == MTLTextureTypeCubeArray ? 6 : 1) - s0);
        MTLTextureType tt = r.v.set_target ? ttype(r.v.target, base.textureType) : base.textureType;
        if (tt == MTLTextureType2D && ns > 1) ns = 1;
        // A view whose level / layer range does not fit the texture (the game registered the ID with a texture and a view that do not belong together;
        // the console samples garbage, Metal's view validation aborts the process): sampled as the whole texture, reported once
        NSUInteger nsl = base.textureType == MTLTextureType3D ? 1 : base.arrayLength * (base.textureType == MTLTextureTypeCube || base.textureType == MTLTextureTypeCubeArray ? 6 : 1);
        if (!nl || l0 + nl > base.mipmapLevelCount || !ns || s0 + ns > nsl) {
            RED_ONCE(73, "texture ID %d: view levels %lu+%lu / layers %lu+%lu do not fit the texture (format %#x, %ux%u, %lu levels, %lu slices, view format %#x): sampled as the whole texture (first case)",
                     tid, (unsigned long)l0, (unsigned long)nl, (unsigned long)s0, (unsigned long)ns, r.t.d.format, r.t.d.width, r.t.d.height, (unsigned long)base.mipmapLevelCount, (unsigned long)nsl, r.v.set_format ? r.v.format : 0);
            l0 = 0; nl = base.mipmapLevelCount; s0 = 0; tt = base.textureType; ns = tt == MTLTextureType2D ? 1 : nsl; pf = (uint32_t)base.pixelFormat;   // a cube's slices stay a multiple of 6
        }
        if (tswz) v = [base newTextureViewWithPixelFormat:(MTLPixelFormat)pf textureType:tt levels:NSMakeRange(l0, nl) slices:NSMakeRange(s0, ns)
                                                 swizzle:MTLTextureSwizzleChannelsMake((MTLTextureSwizzle)esw[0], (MTLTextureSwizzle)esw[1], (MTLTextureSwizzle)esw[2], (MTLTextureSwizzle)esw[3])];
        else v = [base newTextureViewWithPixelFormat:(MTLPixelFormat)pf textureType:tt levels:NSMakeRange(l0, nl) slices:NSMakeRange(s0, ns)];
        if (!v) { RED_ONCE(11, "cannot create texture view id %d", tid); v = base; }
    }
    rp->view = (void *)CFBridgingRetain(v); rp->view_rid = v.gpuResourceID._impl; rp->view_ser = sg; rp->view_dirty = dg; rp->view_kind = kind;
    return v;
}
// Hot-path object fetch: if the table entry is valid, return the table-held pointer directly (without ARC retain / autorelease), otherwise take the slow path to build / validate. Caller holds g_rmu.
static inline __attribute__((always_inline)) void *tex_fast(int tid) {
    if (tid > 0 && tid < g_ntreg && g_treg[tid].ok && g_treg[tid].view && g_treg[tid].view_ser == g_ser_gen && g_treg[tid].view_dirty == treg_stamp(g_treg[tid].view_kind)) return g_treg[tid].view;
    return (__bridge void *)tex_by_id(tid);
}
static inline __attribute__((always_inline)) uint64_t tex_fast_rid(int tid, void **out) {
    if (tid > 0 && tid < g_ntreg && g_treg[tid].ok && g_treg[tid].view && g_treg[tid].view_ser == g_ser_gen && g_treg[tid].view_dirty == treg_stamp(g_treg[tid].view_kind)) { if (out) *out = g_treg[tid].view; return g_treg[tid].view_rid; }
    id<MTLTexture> t = tex_by_id(tid); if (out) *out = (__bridge void *)t; return t ? t.gpuResourceID._impl : 0;
}
// The shader declares another texture type than the bound texture has: bind a compatible view (nxnative 42a50ef, seedds, MIT). Maxwell sample
// instructions carry their own dimension (a non-array sample of a 2D array reads layer 0); on Metal a 2D array bound to a texture2d argument is a type
// mismatch with undefined reads (nxnative measured one fixed value: Super Mario 3D World's one-layer 2D array pre-lighting buffer sampled as 2D washed
// the whole picture out). The supported pairs are in nvn_tex_fit.h; any other mismatch is reported once and bound as it is. The view is kept with
// the texture ID until its view changes. Caller holds g_rmu
static id<MTLTexture> tex_fit(int tid, id<MTLTexture> t, MTLTextureType want, uint64_t *rid) {
    MTLTextureType have = t.textureType; NSUInteger ns = nvn_tex_fit_slices(want, have, t.arrayLength);
    if (!ns || tid <= 0 || tid >= g_ntreg) { RED_ONCE(69, "texture type mismatch: the shader declares %lu, the texture is %lu (texture ID %d: %lux%lux%lu, %lu levels, Metal format %lu, NVN format %#x, serial %llu); bound as it is",
        (unsigned long)want, (unsigned long)have, tid, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.depth, (unsigned long)t.mipmapLevelCount, (unsigned long)t.pixelFormat,
        tid > 0 && tid < g_ntreg ? g_treg[tid].t.d.format : 0, tid > 0 && tid < g_ntreg ? (unsigned long long)g_treg[tid].t.serial : 0ull); return nil; }
    treg_t *r = &g_treg[tid];
    if (r->alt && r->alt_of == (__bridge void *)t && r->alt_type == (uint8_t)want) { *rid = r->alt_rid; return (__bridge id<MTLTexture>)r->alt; }
    treg_alt_drop(r);
    id<MTLTexture> v = nvn_tex_fit_view(t, want, ns);
    if (!v) { RED_ONCE(70, "cannot create a compatible texture view %lu → %lu (texture ID %d)", (unsigned long)have, (unsigned long)want, tid); return nil; }
    static uint64_t n_fit; if (!n_fit++) MLOG("texture bound as another type through a compatible view: %lu → %lu (texture ID %d; first of its kind, tex_fit)", (unsigned long)have, (unsigned long)want, tid);
    r->alt = (void *)CFBridgingRetain(v); r->alt_of = (__bridge void *)t; r->alt_type = (uint8_t)want; r->alt_rid = v.gpuResourceID._impl;
    *rid = r->alt_rid; return v;
}
static MTLSamplerAddressMode wrapm(int w) {
    switch (w) { case 0: case 7: return MTLSamplerAddressModeClampToEdge; case 1: return MTLSamplerAddressModeRepeat;
        case 3: case 2: return MTLSamplerAddressModeMirrorClampToEdge; case 5: case 4: return MTLSamplerAddressModeClampToBorderColor;
        case 6: return MTLSamplerAddressModeMirrorRepeat; }
    return MTLSamplerAddressModeRepeat;
}
static int g_samp_old_once;
static id<MTLSamplerState> samp_by_id(int sid) {   // Caller holds g_rmu
    if (sid < 0 || sid >= g_nsreg || !g_sreg_ok[sid]) { RED_ONCE(12, "sampler ID %d not registered", sid); return nil; }
    if (g_sview[sid]) return (__bridge id<MTLSamplerState>)g_sview[sid];
    samp_par p = g_sreg[sid];
    MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
    d.magFilter = p.magf ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.minFilter = (p.minf == 1 || p.minf == 3 || p.minf == 5) ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.mipFilter = p.minf <= 1 ? MTLSamplerMipFilterNotMipmapped : (p.minf == 2 || p.minf == 3) ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterLinear;
    d.sAddressMode = wrapm(p.ws); d.tAddressMode = wrapm(p.wt); d.rAddressMode = wrapm(p.wr);
    d.lodMinClamp = p.lod_min < 0 ? 0 : p.lod_min; d.lodMaxClamp = p.lod_max;
    d.maxAnisotropy = p.aniso < 1 ? 1 : p.aniso > 16 ? 16 : (NSUInteger)p.aniso;
    if (p.cmp_mode) d.compareFunction = (MTLCompareFunction)(p.cmp_func - 1);
    // LOD bias and min / max reduction (NVN values 0 average, 1 min, 2 max = MTLSamplerReductionMode's) came with macOS / iOS 26: the bias was stored
    // and never applied (Tears of the Kingdom sets it on 861 samplers). Metal ignores the reduction with nearest filtering, as NVN does
    if (@available(macOS 26.0, iOS 26.0, *)) { d.lodBias = p.lod_bias < -16.f ? -16.f : p.lod_bias > 15.999f ? 15.999f : p.lod_bias; d.reductionMode = (MTLSamplerReductionMode)p.reduction; }
    else if ((p.reduction || p.lod_bias != 0.f) && !g_samp_old_once++) MLOG("[red] sampler LOD bias %g / reduction %d need macOS / iOS 26: ignored", p.lod_bias, (int)p.reduction);
    d.borderColor = p.border[3] > 0.5f ? (p.border[0] > 0.5f ? MTLSamplerBorderColorOpaqueWhite : MTLSamplerBorderColorOpaqueBlack) : MTLSamplerBorderColorTransparentBlack;
    d.supportArgumentBuffers = YES;
    id<MTLSamplerState> s = [g_dev newSamplerStateWithDescriptor:d];
    if (s) { g_sview[sid] = (void *)CFBridgingRetain(s); g_srid[sid] = s.gpuResourceID._impl; }
    return s;
}
static inline __attribute__((always_inline)) void *samp_fast(int sid) {
    if (sid > 0 && sid < g_nsreg && g_sreg_ok[sid] && g_sview[sid]) return g_sview[sid];
    return (__bridge void *)samp_by_id(sid);
}

// ---------- Argument buffer blocks: one block per submission, reclaimed after the GPU completes ----------
@interface NvArena : NSObject { @public id<MTLBuffer> buf; uint64_t gpu, fence; size_t used; } @end
@implementation NvArena @end
static NSMutableArray<NvArena *> *g_arenas; static NvArena *g_cur_arena; static NSMutableArray<NvArena *> *g_sub_arenas;
static NvArena *arena_new(void) {
    // The for-in loop variable does not retain the object: take a strong reference first and then remove it from the array, otherwise what is returned after the array releases it is a dangling pointer
    for (NvArena *it in g_arenas) if (it->fence && it->fence <= g_done) { NvArena *r = it; [g_arenas removeObject:r]; r->fence = 0; r->used = 0; return r; }
    NvArena *a = [NvArena new]; a->buf = [g_dev newBufferWithLength:4 << 20 options:MTLResourceStorageModeShared]; a->gpu = a->buf.gpuAddress; res_add(a->buf); return a;
}
void arena_begin(void) { if (!g_arenas) { g_arenas = [NSMutableArray array]; g_sub_arenas = [NSMutableArray array]; } g_cur_arena = nil; }
void arena_commit(uint64_t fence) { for (NvArena *a in g_sub_arenas) { a->fence = fence; [g_arenas addObject:a]; } [g_sub_arenas removeAllObjects]; g_cur_arena = nil; }
static size_t arena_alloc(size_t n, id<MTLBuffer> *buf) {
    n = (n + 255) & ~(size_t)255;
    if (!g_cur_arena || g_cur_arena->used + n > g_cur_arena->buf.length) {
        pthread_mutex_lock(&g_mu); g_cur_arena = arena_new(); pthread_mutex_unlock(&g_mu);
        [g_sub_arenas addObject:g_cur_arena];
    }
    size_t off = g_cur_arena->used; g_cur_arena->used += n; *buf = g_cur_arena->buf; return off;
}

// ---------- Draw state ----------
static struct {
    const prog_t *prog;
    blend_st blend[8]; color_st color; chmask_st chmask; ms_st ms; poly_st poly; ds_st ds;
    va_st attr[16]; int nattr; vs_st stream[16]; int nstream;
    NVNbufferRange vbuf[16];
    p_bind_buf ubo[6][16], ssbo[6][16];
    uint64_t tex[6][128], samp[6][128], img[6][32];
    uint32_t st_vmask[2], st_wmask[2], st_ref[2];
    p_poly_offset po; float vp[16][4]; float dr[2]; int has_vp; int depth_clamp;
    int restart_set, restart_en; uint32_t restart_idx;   // SetPrimitiveRestart (restart_set: the game has set it; its default is not documented)
    float blend_color[4], alpha_ref; int64_t copy_stride, copy_image_stride;
} S;
static uint32_t cur_chmask(void) { return S.chmask.mask; }
// BindProgram attaches a program per stage bit (NVN semantics: only the stages in stages are replaced, the others keep their binding; a program without a shader for that stage = that stage is unbound).
// Unity's programs each contain a single stage and vertex / pixel are bound in two calls; D2R binds all stages at once, which is why replacing the whole program used to happen to work.
// The replay layer represents the current program everywhere as a single prog_t: the per-stage keys are combined here into a composite prog_t (deduplicated by the 6 stage keys, kept alive, with its own serial), and prog_get resolves it as usual.
static const prog_t *prog_bind(const prog_t *cur, const prog_t *np, int stages) {
    if (np && !np->nstage) return np;   // a program without keys (unit-test objects that register an NvProg straight into the serial table): replaced as a whole, as before
    uint8_t k[6][8] = {{0}}; uint8_t have[6] = {0};
    if (cur) for (unsigned i = 0; i < cur->nstage && i < 6; i++) { unsigned st = cur->kstage[i]; if (st < 6 && !(stages & (1 << st))) { memcpy(k[st], cur->key[i], 8); have[st] = 1; } }
    if (np) for (unsigned i = 0; i < np->nstage && i < 6; i++) { unsigned st = np->kstage[i]; if (st < 6 && (stages & (1 << st))) { memcpy(k[st], np->key[i], 8); have[st] = 1; } }
    if (np) {   // the composite is exactly np's own key set (all its stages bound at once, other stages empty): use np itself, the same object as D2R's whole-program bind
        int same = 1; unsigned cnt = 0; for (unsigned st = 0; st < 6; st++) cnt += have[st];
        if (cnt != np->nstage) same = 0;
        for (unsigned i = 0; same && i < np->nstage; i++) { unsigned st = np->kstage[i]; if (st >= 6 || !have[st] || memcmp(k[st], np->key[i], 8)) same = 0; }
        if (same) return np;
    }
    uint8_t hk[6 * 8 + 6]; memcpy(hk, k, 48); memcpy(hk + 48, have, 6);
    static nvn_hmap cache; static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mu);
    if (!cache.klen) nvn_hm_init(&cache, sizeof hk);
    prog_t *c = nvn_hm_get(&cache, hk);
    if (!c) {
        static uint64_t nc; c = calloc(1, sizeof *c); c->magic = MAGIC('P', 'R', 'G', 'C'); c->serial = (1ull << 62) | ++nc;   // composite programs have their own serial range (top bits), never colliding with the texture / program serials from nvn_new_serial
        for (unsigned st = 0; st < 6; st++) if (have[st]) { memcpy(c->key[c->nstage], k[st], 8); c->kstage[c->nstage] = (uint8_t)st; c->nstage++; }
        nvn_hm_put(&cache, hk, c);
    }
    pthread_mutex_unlock(&mu);
    return c->nstage ? c : NULL;
}
static uint64_t g_udc_rt_walks;   // attachment walks of udc_note_draw (once per pass and attachment set; t_poolcache counts them)
static void udc_note_draw(NvProg *pr) {
    // Zero-source set: an attachment really drawn is no longer all zeros. Done for the first draw of a pass (and again if its attachments change):
    // later draws of the pass would find nothing left to remove (upstream afad65c keeps one draw's attachment events per pass)
    { static uint64_t pass = UINT64_MAX, sig; uint64_t s = (uint64_t)R.rt.n; for (int i = 0; i < R.rt.n && i < 8; i++) s = s * 1000003u ^ (R.rt.color[i] ? R.rt.color[i]->serial : 0);
      if (R.has_rt && (pass != g_stat_pass || sig != s)) { pass = g_stat_pass; sig = s; g_udc_rt_walks++;
          for (int i = 0; i < R.rt.n && i < 8; i++) if (R.rt.color[i]) { zskip_del(R.rt.color[i]->serial); g_zskip_cand_ok[i] = 0; } } }
    if (pr) prog_summary(pr);
    if (pr && pr->sum_img) zskip_clear();   // Image slots are writable: conservatively clear
    int image_write = pr ? pr->sum_imgw : 0;
    uint32_t shader_color_mask = pr ? pr->sum_cmask : 0;
    if (R.has_rt && g_enc) for (int i = 0; i < R.rt.n && i < 8; i++)   // a slot left out of this pass (see rt_dup_slot) really written: those writes are lost
        if ((shader_color_mask >> i & 1) && ((S.chmask.mask >> (4 * i)) & 0xf) && (g_rt_dup_skip >> i & 1))
            RED_ONCE(80, "colour slot %d attaches the same texture as another slot (ser=%llu) and this draw writes it (mask %#x): those writes are lost", i, (unsigned long long)R.rt.color[i]->serial, (S.chmask.mask >> (4 * i)) & 0xf);
    for (int i = 0; i < g_nsd; i++) {
        sd_att *t = &g_sd[i];
        if (image_write) { t->wrote = 1; t->wwhy = 1; }
        else if (t->depth == 0 && t->idx >= 0 && (((S.chmask.mask >> (4 * t->idx)) & 0xf) || (shader_color_mask >> t->idx & 1))) { t->wrote = 1; t->wwhy = (S.chmask.mask >> (4 * t->idx)) & 0xf ? 2 : 3; }
        else if (t->depth == 1 && S.ds.dw) { t->wrote = 1; t->wwhy = 4; }
        else if (t->depth == 2 && S.ds.st && (S.st_wmask[0] || S.st_wmask[1])
                && (S.ds.fail_f != NVN_STENCIL_OP_KEEP || S.ds.zfail_f != NVN_STENCIL_OP_KEEP || S.ds.zpass_f != NVN_STENCIL_OP_KEEP
                    || S.ds.fail_b != NVN_STENCIL_OP_KEEP || S.ds.zfail_b != NVN_STENCIL_OP_KEEP || S.ds.zpass_b != NVN_STENCIL_OP_KEEP)) { t->wrote = 1; t->wwhy = 5; }
    }
}
static void state_reset(void) {
    memset(&S, 0, sizeof S);
    g_pso_dirty = g_dss_dirty = 1;
    for (int i = 0; i < 8; i++) S.blend[i] = (blend_st){i, NVN_BLEND_FUNC_ONE, NVN_BLEND_FUNC_ZERO, NVN_BLEND_FUNC_ONE, NVN_BLEND_FUNC_ZERO, NVN_BLEND_EQUATION_ADD, NVN_BLEND_EQUATION_ADD};
    S.color = (color_st){0, NVN_LOGIC_OP_COPY, NVN_ALPHA_FUNC_ALWAYS}; S.chmask.mask = 0xffffffffu;
    S.poly = (poly_st){NVN_FACE_NONE, NVN_FRONT_FACE_CCW, NVN_POLYGON_MODE_FILL, 0};
    S.ds = (ds_st){0, 1, NVN_DEPTH_FUNC_LESS, 0, NVN_STENCIL_FUNC_ALWAYS, NVN_STENCIL_FUNC_ALWAYS, 1, 1, 1, 1, 1, 1};
    S.st_vmask[0] = S.st_vmask[1] = S.st_wmask[0] = S.st_wmask[1] = 0xff; S.dr[1] = 1;
}

static MTLVertexFormat vfmt(int f) {
    switch (f) {
        case 0x01: return MTLVertexFormatUCharNormalized; case 0x02: return MTLVertexFormatCharNormalized; case 0x03: return MTLVertexFormatUChar; case 0x04: return MTLVertexFormatChar;
        case 0x05: return MTLVertexFormatHalf; case 0x06: return MTLVertexFormatUShortNormalized; case 0x07: return MTLVertexFormatShortNormalized;
        case 0x08: return MTLVertexFormatUShort; case 0x09: return MTLVertexFormatShort; case 0x0A: return MTLVertexFormatFloat; case 0x0B: return MTLVertexFormatUInt; case 0x0C: return MTLVertexFormatInt;
        case 0x0D: return MTLVertexFormatUChar2Normalized; case 0x0E: return MTLVertexFormatChar2Normalized; case 0x0F: return MTLVertexFormatUChar2; case 0x10: return MTLVertexFormatChar2;
        case 0x11: return MTLVertexFormatHalf2; case 0x12: return MTLVertexFormatUShort2Normalized; case 0x13: return MTLVertexFormatShort2Normalized; case 0x14: return MTLVertexFormatUShort2;
        case 0x15: return MTLVertexFormatShort2; case 0x16: return MTLVertexFormatFloat2; case 0x17: return MTLVertexFormatUInt2; case 0x18: return MTLVertexFormatInt2;
        case 0x19: return MTLVertexFormatUChar3Normalized; case 0x1A: return MTLVertexFormatChar3Normalized; case 0x1B: return MTLVertexFormatUChar3; case 0x1C: return MTLVertexFormatChar3;
        case 0x1D: return MTLVertexFormatHalf3; case 0x1E: return MTLVertexFormatUShort3Normalized; case 0x1F: return MTLVertexFormatShort3Normalized; case 0x20: return MTLVertexFormatUShort3;
        case 0x21: return MTLVertexFormatShort3; case 0x22: return MTLVertexFormatFloat3; case 0x23: return MTLVertexFormatUInt3; case 0x24: return MTLVertexFormatInt3;
        case 0x25: return MTLVertexFormatUChar4Normalized; case 0x26: return MTLVertexFormatChar4Normalized; case 0x27: return MTLVertexFormatUChar4; case 0x28: return MTLVertexFormatChar4;
        case 0x29: return MTLVertexFormatHalf4; case 0x2A: return MTLVertexFormatUShort4Normalized; case 0x2B: return MTLVertexFormatShort4Normalized; case 0x2C: return MTLVertexFormatUShort4;
        case 0x2D: return MTLVertexFormatShort4; case 0x2E: return MTLVertexFormatFloat4; case 0x2F: return MTLVertexFormatUInt4; case 0x30: return MTLVertexFormatInt4;
        case 0x3D: return MTLVertexFormatUInt1010102Normalized; case 0x69: return MTLVertexFormatInt1010102Normalized;   // RGB10A2SN (TotK full-screen quads; nxnative)
        case 0x3F: return MTLVertexFormatFloatRG11B10; case 0x9A: return MTLVertexFormatUChar4Normalized_BGRA;
        // *_UI2F / *_I2F: the integer converted to its float value (BotW's uking_grass uses RG8_UI2F; jiangjifeng's nxnative fork ae9082d). Metal does
        // exactly that for an 8 / 16-bit integer format read into a float input (measured on an M5: UChar2 17 / 203 read as 17.0 / 203.0, Short2 -32768 as
        // -32768.0); it refuses 32-bit integers for a float input, so the 32-bit and 10:10:10:2 kinds stay unmapped (red 15)
        case 0x51: return MTLVertexFormatUChar; case 0x52: return MTLVertexFormatChar; case 0x53: return MTLVertexFormatUShort; case 0x54: return MTLVertexFormatShort;
        case 0x57: return MTLVertexFormatUChar2; case 0x58: return MTLVertexFormatChar2; case 0x59: return MTLVertexFormatUShort2; case 0x5A: return MTLVertexFormatShort2;
        case 0x5D: return MTLVertexFormatUChar3; case 0x5E: return MTLVertexFormatChar3; case 0x5F: return MTLVertexFormatUShort3; case 0x60: return MTLVertexFormatShort3;
        case 0x63: return MTLVertexFormatUChar4; case 0x64: return MTLVertexFormatChar4; case 0x65: return MTLVertexFormatUShort4; case 0x66: return MTLVertexFormatShort4;
    }
    return MTLVertexFormatInvalid;
}
static int vfmt_scaled(int f) { return (f >= 0x51 && f <= 0x54) || (f >= 0x57 && f <= 0x5A) || (f >= 0x5D && f <= 0x60) || (f >= 0x63 && f <= 0x66); }   // the *_UI2F / *_I2F vfmt maps
// Integer vertex formats meeting a float shader input. Maxwell hands integer attributes to the shader unconverted (the raw 32-bit integers), and the
// translated shaders keep attributes in float registers and bit-cast where the original used integer instructions. Metal refuses a 32-bit integer format
// for a float input ("cannot be read using MTLAttributeFormatUInt"), so those are fetched as the float format of the same width: the shader sees the same
// bits. 8 / 16-bit integer formats Metal converts to their float value, not the bits the shader expects: they stay as they are (logged once)
static MTLVertexFormat vfmt_for_float_input(MTLVertexFormat f) {
    switch (f) {
        case MTLVertexFormatUInt: case MTLVertexFormatInt: return MTLVertexFormatFloat;
        case MTLVertexFormatUInt2: case MTLVertexFormatInt2: return MTLVertexFormatFloat2;
        case MTLVertexFormatUInt3: case MTLVertexFormatInt3: return MTLVertexFormatFloat3;
        case MTLVertexFormatUInt4: case MTLVertexFormatInt4: return MTLVertexFormatFloat4;
        default: return f;
    }
}
static int vfmt_is_int(MTLVertexFormat f) {
    switch (f) {
        case MTLVertexFormatUChar: case MTLVertexFormatChar: case MTLVertexFormatUChar2: case MTLVertexFormatChar2: case MTLVertexFormatUChar3: case MTLVertexFormatChar3:
        case MTLVertexFormatUChar4: case MTLVertexFormatChar4: case MTLVertexFormatUShort: case MTLVertexFormatShort: case MTLVertexFormatUShort2: case MTLVertexFormatShort2:
        case MTLVertexFormatUShort3: case MTLVertexFormatShort3: case MTLVertexFormatUShort4: case MTLVertexFormatShort4: case MTLVertexFormatUInt: case MTLVertexFormatInt:
        case MTLVertexFormatUInt2: case MTLVertexFormatInt2: case MTLVertexFormatUInt3: case MTLVertexFormatInt3: case MTLVertexFormatUInt4: case MTLVertexFormatInt4: return 1;
        default: return 0;
    }
}
static int vfmt_is_signed(MTLVertexFormat f) {
    switch (f) { case MTLVertexFormatChar: case MTLVertexFormatChar2: case MTLVertexFormatChar3: case MTLVertexFormatChar4: case MTLVertexFormatShort: case MTLVertexFormatShort2:
        case MTLVertexFormatShort3: case MTLVertexFormatShort4: case MTLVertexFormatInt: case MTLVertexFormatInt2: case MTLVertexFormatInt3: case MTLVertexFormatInt4: return 1; default: return 0; }
}
static MTLBlendFactor bfac(int f) {
    switch (f) { case 1: return MTLBlendFactorZero; case 2: return MTLBlendFactorOne; case 3: return MTLBlendFactorSourceColor; case 4: return MTLBlendFactorOneMinusSourceColor;
        case 5: return MTLBlendFactorSourceAlpha; case 6: return MTLBlendFactorOneMinusSourceAlpha; case 7: return MTLBlendFactorDestinationAlpha; case 8: return MTLBlendFactorOneMinusDestinationAlpha;
        case 9: return MTLBlendFactorDestinationColor; case 10: return MTLBlendFactorOneMinusDestinationColor; case 11: return MTLBlendFactorSourceAlphaSaturated;
        case 0x10: return MTLBlendFactorSource1Color; case 0x11: return MTLBlendFactorOneMinusSource1Color; case 0x12: return MTLBlendFactorSource1Alpha; case 0x13: return MTLBlendFactorOneMinusSource1Alpha;
        case 0x61: return MTLBlendFactorBlendColor; case 0x62: return MTLBlendFactorOneMinusBlendColor; case 0x63: return MTLBlendFactorBlendAlpha; case 0x64: return MTLBlendFactorOneMinusBlendAlpha; }
    return MTLBlendFactorOne;
}
static MTLBlendOperation bop(int e) { switch (e) { case 2: return MTLBlendOperationSubtract; case 3: return MTLBlendOperationReverseSubtract; case 4: return MTLBlendOperationMin; case 5: return MTLBlendOperationMax; } return MTLBlendOperationAdd; }

// Pipeline: cached by (program, target formats, blend / write mask, vertex layout, sample count)
static const uint8_t *g_pso_lmap; static id<MTLFunction> g_pso_fsfn; static pso_fz_desc g_pso_fz, g_fz_desc;
static os_unfair_lock g_fz_fn_lock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, id<MTLFunction>> *g_bf_fn_cache;
static NSMutableDictionary<NSString *, id<MTLLibrary>> *g_bf_lib_cache;
static nvn_hmap g_pso = {.klen = sizeof(pso_key)}, g_dss;
static nvn_hmap g_pso_fail = {.klen = sizeof(pso_key)};   // keys whose pipeline failed to build: not rebuilt on every draw (each attempt is a synchronous compile)
// The main0_vi variant specialized for these unsigned / signed locations (function constants 128 + loc / 144 + loc, dmsh_build.py vi_variant); cached per
// shader. pso_desc also runs on the warm-up threads, hence the lock
static id<MTLFunction> vi_function(NvShader *vs, uint32_t u, uint32_t sg) {
    NSNumber *key = @((uint64_t)u | (uint64_t)sg << 32);
    @synchronized (vs) {
        id<MTLFunction> f = vs->vi_fns[key]; if (f) return f;
        MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new]; bool t = true;
        for (int l = 0; l < 16; l++) { if (u >> l & 1) [cv setConstantValue:&t type:MTLDataTypeBool atIndex:128 + l]; if (sg >> l & 1) [cv setConstantValue:&t type:MTLDataTypeBool atIndex:144 + l]; }
        NSError *e = nil; f = [vs->vi_lib newFunctionWithName:vs->vi_entry constantValues:cv error:&e];
        if (!f) { MLOG("[red] vertex shader %s: specializing %s failed: %s", vs->key, vs->vi_entry.UTF8String, e.localizedDescription.UTF8String); return nil; }
        if (!vs->vi_fns) vs->vi_fns = [NSMutableDictionary dictionary];
        vs->vi_fns[key] = f; return f;
    }
}
// The alpha test (NVN ColorStateSetAlphaTest + CommandBufferSetAlphaRef; Metal has none), after lordran-native a63dd76 (MIT): when the game profile
// asks for it (game.json alpha_test), every fragment shader ends with a comparison of colour 0's alpha under function constants 160 (the NVN
// comparison) and 161 (the reference) (dmsh_build.py alpha_test). Metal builds no pipeline from an unspecialized function, so such a shader is
// specialized with ALWAYS at load (the comparison and its discard fold away) and a draw with another comparison uses a specialization cached per
// shader, comparison and reference. A shader built without it draws without the test (red once). Checked by gfx/tests/t_alpha.m
static int alpha_on(void) { return S.color.alpha_func && S.color.alpha_func != NVN_ALPHA_FUNC_ALWAYS; }
static id<MTLFunction> alpha_spec(id<MTLLibrary> lib, NSString *entry, uint32_t func, uint32_t refbits, NSError **e) {
    MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new]; float ref; memcpy(&ref, &refbits, sizeof ref);
    [cv setConstantValue:&func type:MTLDataTypeUInt atIndex:160]; [cv setConstantValue:&ref type:MTLDataTypeFloat atIndex:161];
    return [lib newFunctionWithName:entry constantValues:cv error:e];
}
static id<MTLFunction> alpha_plain(id<MTLLibrary> lib, NSString *entry) {   // shader_load: the function as drawn without an alpha test
    NSError *e = nil; id<MTLFunction> fn = alpha_spec(lib, entry, NVN_ALPHA_FUNC_ALWAYS, 0, &e);
    if (!fn) MLOG("[red] fragment function %s: specialization without an alpha test failed: %s", entry.UTF8String, e.localizedDescription.UTF8String);
    return fn;
}
static id<MTLFunction> alpha_fn(const pso_key *k, NvShader *fs) {
    if (!fs) return nil;
    if (!k->alpha_func) return fs->fn;
    if (!fs->alib) { RED_ONCE(95, "alpha test %u on fragment shader %s, built without it (game.json alpha_test is off): drawn without the test", k->alpha_func, fs->key); return fs->fn; }
    uint64_t bits = (uint64_t)k->alpha_func << 32 | k->alpha_ref;
    @synchronized (fs) {
        if (!fs->afn) fs->afn = [NSMutableDictionary dictionary];
        id<MTLFunction> fn = fs->afn[@(bits)];
        if (fn) return fn;
        uint32_t func = k->alpha_func; float ref; memcpy(&ref, &k->alpha_ref, sizeof ref);
        NSError *e = nil; fn = alpha_spec(fs->alib, fs->fn.name, func, k->alpha_ref, &e);
        if (!fn) { MLOG("[red] alpha test specialization of %s failed: %s", fs->key, e.localizedDescription.UTF8String); return fs->fn; }
        fs->afn[@(bits)] = fn;
        static _Atomic unsigned nspec; unsigned c = atomic_fetch_add(&nspec, 1) + 1; if (c == 1 || !(c & (c - 1))) MLOG("alpha test: %u fragment shader specializations so far (latest %s, comparison %u, reference %g)", c, fs->key, func, ref);
        return fn;
    }
}
static MTLRenderPipelineDescriptor *pso_desc(const pso_key *k, NvShader *vs, NvShader *fs, id<MTLFunction> fsfn, int merged) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = vs->fn; d.fragmentFunction = fsfn ? fsfn : alpha_fn(k, fs);
    // Diagnostic DM_NVN_HILITE=fragment shader key,...: these draws use a solid-color fragment instead (keys 1–6 in order magenta / green / cyan / yellow / blue / white), to see where the geometry lands
    if (fs) { static char keys[6][24]; static int nk = -1; static id<MTLLibrary> hl;
        if (nk < 0) { nk = 0; const char *e = getenv("DM_NVN_HILITE");
            for (const char *q = e; q && *q && nk < 6; q = strchr(q, ',') ? strchr(q, ',') + 1 : q + strlen(q)) { size_t n = strcspn(q, ","); if (n > 23) n = 23; memcpy(keys[nk], q, n); keys[nk++][n] = 0; } }
        for (int i = 0; i < nk; i++) if (!strncmp(fs->key, keys[i], strlen(keys[i]))) {
            if (!hl) { NSError *e = nil; hl = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nstruct O { float4 c0 [[color(0)]]; float4 c1 [[color(1)]]; float4 c2 [[color(2)]]; };\n"
                "fragment O hl0() { return {float4(1,0,1,1),float4(1,0,1,1),float4(1,0,1,1)}; } fragment O hl1() { return {float4(0,1,0,1),float4(0,1,0,1),float4(0,1,0,1)}; }\n"
                "fragment O hl2() { return {float4(0,1,1,1),float4(0,1,1,1),float4(0,1,1,1)}; } fragment O hl3() { return {float4(1,1,0,1),float4(1,1,0,1),float4(1,1,0,1)}; }\n"
                "fragment O hl4() { return {float4(0,0,1,1),float4(0,0,1,1),float4(0,0,1,1)}; } fragment O hl5() { return {float4(1,1,1,1),float4(1,1,1,1),float4(1,1,1,1)}; }\n" options:nil error:&e];
                if (!hl) MLOG("[red] HILITE shader compile failed %s", e.localizedDescription.UTF8String); }
            if (hl) d.fragmentFunction = [hl newFunctionWithName:[NSString stringWithFormat:@"hl%d", i]];
            break; } }
    d.rasterSampleCount = k->samples ? k->samples : 1;
    d.alphaToCoverageEnabled = (k->a2c & 1) != 0;
    if (k->a2c & PSO_LAYERED) d.maxVertexAmplificationCount = 2;   // a layered pass: the view mapping picks the layer (no topology class: one would refuse vertex shaders that write point size, t_layer)
    for (int i = 0; i < 8; i++) {
        if (!k->cfmt[i]) continue;
        MTLRenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[i];
        c.pixelFormat = (MTLPixelFormat)k->cfmt[i];
        int l = merged ? k->lmap[i] : i;
        uint32_t m = l == 0xff ? 0 : (k->chmask >> (4 * l)) & 0xf;
        // An output the fragment shader does not write: zero write mask, no blending (nxnative 42a50ef). Maxwell writes only the targets in the shader's
        // output map and leaves the others untouched, whatever the blend state and channel mask; on Metal an attachment the shader does not write gets
        // undefined contents, blended in when blending is on
        int unwritten = fs && fs->rf.color_known && !fsfn && l != 0xff && !(fs->rf.color_mask >> l & 1);
        if (unwritten) m = 0;
        c.writeMask = (m & 1 ? MTLColorWriteMaskRed : 0) | (m & 2 ? MTLColorWriteMaskGreen : 0) | (m & 4 ? MTLColorWriteMaskBlue : 0) | (m & 8 ? MTLColorWriteMaskAlpha : 0);
        if (l != 0xff && k->blend_en >> l & 1 && !unwritten) {
            c.blendingEnabled = YES;
            c.sourceRGBBlendFactor = bfac(k->blend[l].src_rgb); c.destinationRGBBlendFactor = bfac(k->blend[l].dst_rgb);
            c.sourceAlphaBlendFactor = bfac(k->blend[l].src_a); c.destinationAlphaBlendFactor = bfac(k->blend[l].dst_a);
            c.rgbBlendOperation = bop(k->blend[l].eq_rgb); c.alphaBlendOperation = bop(k->blend[l].eq_a);
        }
    }
    d.depthAttachmentPixelFormat = (MTLPixelFormat)k->dfmt; d.stencilAttachmentPixelFormat = (MTLPixelFormat)k->sfmt;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    const nvn_refl *rf = &vs->rf; uint32_t vi_u = 0, vi_s = 0;
    for (int v = 0; v < rf->nv; v++) {
        int loc = rf->v[v].loc, a = rf->v[v].nvn;   // Metal slot loc ← NVN attribute a
        MTLVertexFormat vf = a < 16 ? vfmt(k->attr[a].fmt) : MTLVertexFormatInvalid;
        // When a >= S.nattr, k.attr[a] keeps the 0 from memset, vfmt(0) is Invalid, the same fallback branch is taken and the RED_ONCE condition of fmt being non-0 does not hold.
        if (a < 16 && k->attr[a].fmt && vf == MTLVertexFormatInvalid) RED_ONCE(15, "vertex attribute format %#x not mapped", k->attr[a].fmt);
        if (vf == MTLVertexFormatInvalid) {
            int ct = rf->v[v].ct;
            vd.attributes[loc].format = ct == NVN_CT_UINT ? MTLVertexFormatUInt4 : ct == NVN_CT_INT ? MTLVertexFormatInt4 : MTLVertexFormatFloat4;
            vd.attributes[loc].offset = 0; vd.attributes[loc].bufferIndex = 30;
            vd.layouts[30].stride = 16; vd.layouts[30].stepFunction = MTLVertexStepFunctionConstant; vd.layouts[30].stepRate = 0;
            continue;
        }
        int st = k->attr[a].stream;
        if (rf->v[v].ct == NVN_CT_FLOAT && vfmt_is_int(vf) && !vfmt_scaled(k->attr[a].fmt)) {   // (the *_UI2F / *_I2F formats want Metal's conversion)
            // Integer format, float input: the shader's main0_vi variant takes it as uint / int (same bits); without a variant, 32-bit formats are fetched as
            // float of the same width (same bits as well); 8 / 16-bit ones get Metal's conversion to the value, not the bits (logged once per shader)
            const char *how;
            if (loc < 16 && (vs->vi_mask >> loc & 1)) { if (vfmt_is_signed(vf)) vi_s |= 1u << loc; else vi_u |= 1u << loc; how = "specialized variant main0_vi"; }
            else { MTLVertexFormat ff = vfmt_for_float_input(vf); how = ff == vf ? NULL : "fetched as float of the same width (same bits)"; vf = ff; }
            static char seen[64][24]; static int nseen; static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;   // one line per vertex shader
            pthread_mutex_lock(&mu); int dup = 0; for (int i = 0; i < nseen; i++) if (!strcmp(seen[i], vs->key)) dup = 1;
            if (!dup && nseen < 64) strlcpy(seen[nseen++], vs->key, sizeof seen[0]);
            pthread_mutex_unlock(&mu);
            if (!dup) MLOG("%svertex shader %s: NVN attribute %d (format %#x) is integer, the shader input is float: %s", how ? "" : "[red] ", vs->key, a, k->attr[a].fmt,
                           how ? how : "no variant: an 8 / 16-bit value reaches the shader converted to float, not as its bits");
        }
        vd.attributes[loc].format = vf; vd.attributes[loc].offset = k->attr[a].offset; vd.attributes[loc].bufferIndex = 16 + st;
        vd.layouts[16 + st].stride = k->stream[st].stride ? k->stream[st].stride : 4;
        vd.layouts[16 + st].stepFunction = k->stream[st].stride == 0 ? MTLVertexStepFunctionConstant : k->stream[st].divisor ? MTLVertexStepFunctionPerInstance : MTLVertexStepFunctionPerVertex;
        vd.layouts[16 + st].stepRate = k->stream[st].stride == 0 ? 0 : k->stream[st].divisor ? k->stream[st].divisor : 1;
    }
    d.vertexDescriptor = vd;
    if (vi_u | vi_s) { id<MTLFunction> f = vi_function(vs, vi_u, vi_s); if (f) d.vertexFunction = f; }
    return d;
}
// Pipeline key: current state S + pass formats (normal pass; a merged pass additionally carries lmap / specialized function, filled in by pso_get)
static void pso_key_fill(pso_key *k, NvShader *vs, NvShader *fs, const uint32_t cfmt[8], uint32_t dfmt, uint32_t sfmt, uint32_t samples, int lmap) {
    memset(k, 0, sizeof *k);
    k->vs = (__bridge void *)vs; k->fs = (__bridge void *)fs;
    memcpy(k->cfmt, cfmt, sizeof k->cfmt); k->dfmt = dfmt; k->sfmt = sfmt; k->samples = samples;
    k->blend_en = S.color.blend_en; k->chmask = S.chmask.mask; k->a2c = S.ms.a2c | (g_lay.active ? PSO_LAYERED : 0);
    if (alpha_on()) { k->alpha_func = S.color.alpha_func; memcpy(&k->alpha_ref, &S.alpha_ref, sizeof k->alpha_ref); }
    for (int i = 0; i < 8; i++) if (k->cfmt[i] || lmap) k->blend[i] = S.blend[i];
    const nvn_refl *rf = &vs->rf;
    for (int v = 0; v < rf->nv; v++) { int a = rf->v[v].nvn; if (a < 16 && a < S.nattr) { k->attr[a] = S.attr[a]; int st = S.attr[a].stream; if (st < 16) k->stream[st] = S.stream[st]; } }
}
// ---- Parallel precompile: pipelines met for the first time used to be compiled synchronously one by one on the submit thread; 9 misses in a row in one frame = 284 ms (heavy scene on a real device).
// Now: on the first pipeline miss in a submission, scan ahead once along the remaining commands (replaying state only, no drawing) and kick all the normal-pass pipelines that will also miss later to the background to compile in parallel;
// when the submit thread reaches that draw it only waits for 'the remaining time not yet compiled'. The compiled pipelines are identical to synchronously compiled ones (same descriptor). Pipeline keys of merged passes / specialized fragments depend on the planning result at replay time, are not predicted, and are compiled synchronously as before.
#define PSO_PEND_MAX 384
static struct { pso_key k; id<MTLRenderPipelineState> ps; int used, done; } g_pp[PSO_PEND_MAX];
static pthread_mutex_t g_pp_mu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t g_pp_cv = PTHREAD_COND_INITIALIZER;
static uint64_t g_pp_submit_mark, g_pp_kicked, g_pp_taken;   // Whether this submission has already been predicted (by submission serial); cumulative kicked / taken counts
static void pso_predict_rest(void);
static int pso_pend_find(const pso_key *k) { for (int i = 0; i < PSO_PEND_MAX; i++) if (g_pp[i].used && !memcmp(&g_pp[i].k, k, sizeof *k)) return i; return -1; }
static void pso_pend_kick(const pso_key *k, NvShader *vs, NvShader *fs) {   // Called by the submit thread: kick only if it is neither in the cache nor in the table
    if (hm_get_id(&g_pso, k)) return;
    pthread_mutex_lock(&g_pp_mu);
    int at = pso_pend_find(k), slot = -1;
    if (at < 0) for (int i = 0; i < PSO_PEND_MAX; i++) if (!g_pp[i].used) { slot = i; break; }
    if (at < 0 && slot >= 0) { g_pp[slot].k = *k; g_pp[slot].ps = nil; g_pp[slot].done = 0; g_pp[slot].used = 1; }
    pthread_mutex_unlock(&g_pp_mu);
    if (at >= 0 || slot < 0) return;
    MTLRenderPipelineDescriptor *d = pso_desc(k, vs, fs, nil, 0); g_pp_kicked++;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *e = nil; id<MTLRenderPipelineState> ps = [g_dev newRenderPipelineStateWithDescriptor:d error:&e];
        pthread_mutex_lock(&g_pp_mu); g_pp[slot].ps = ps; g_pp[slot].done = 1; pthread_cond_broadcast(&g_pp_cv); pthread_mutex_unlock(&g_pp_mu);
    });
}
static id<MTLRenderPipelineState> pso_pend_take(const pso_key *k) {   // Called by the submit thread: if it is in the table, wait for it to finish compiling and take it; otherwise return nil
    pthread_mutex_lock(&g_pp_mu);
    int at = pso_pend_find(k); id<MTLRenderPipelineState> ps = nil;
    if (at >= 0) { while (!g_pp[at].done) pthread_cond_wait(&g_pp_cv, &g_pp_mu); ps = g_pp[at].ps; g_pp[at].ps = nil; g_pp[at].used = 0; }
    pthread_mutex_unlock(&g_pp_mu);
    return ps;
}
// 1 / 2: the colour format is unsigned / signed integer (a fragment shader built with float outputs cannot write it)
static int pf_int_kind(MTLPixelFormat f) {
    switch (f) {
        case MTLPixelFormatR8Uint: case MTLPixelFormatR16Uint: case MTLPixelFormatRG8Uint: case MTLPixelFormatR32Uint: case MTLPixelFormatRG16Uint: case MTLPixelFormatRGBA8Uint:
        case MTLPixelFormatRGB10A2Uint: case MTLPixelFormatRG32Uint: case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA32Uint: return 1;
        case MTLPixelFormatR8Sint: case MTLPixelFormatR16Sint: case MTLPixelFormatRG8Sint: case MTLPixelFormatR32Sint: case MTLPixelFormatRG16Sint: case MTLPixelFormatRGBA8Sint:
        case MTLPixelFormatRG32Sint: case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRGBA32Sint: return 2;
        default: return 0;
    }
}
// A pipeline failed: the integer colour attachments its pixel shader writes go to <DM_SHDUMP>/fout.tsv ("<key> <target> uint|sint"), from which
// dmsh_build.py builds that shader with integer outputs (the translator's fragment output types; float by default). Each target once per process
static void fout_note(NvShader *fs, const uint32_t cfmt[8]) {
    static char seen[64][20]; static int nseen;
    for (int i = 0; i < 8; i++) {
        int k = pf_int_kind((MTLPixelFormat)cfmt[i]);
        if (!k || (fs->rf.color_known && !(fs->rf.color_mask >> i & 1))) continue;
        char key[20]; snprintf(key, sizeof key, "%.16s%d", fs->key, i); int dup = 0;
        for (int j = 0; j < nseen; j++) dup |= !strcmp(seen[j], key);
        if (dup) continue;
        if (nseen < 64) strcpy(seen[nseen++], key);
        const char *dir = getenv("DM_SHDUMP"); char path[1024]; FILE *f = NULL;
        if (dir) { snprintf(path, sizeof path, "%s/fout.tsv", dir); f = fopen(path, "a"); }
        if (f) { fprintf(f, "%.16s\t%d\t%s\n", fs->key, i, k == 1 ? "uint" : "sint"); fclose(f); }
        MLOG("[red] pixel shader %.16s writes float to integer colour attachment %d (Metal format %u): %s", fs->key, i, cfmt[i],
             f ? "noted in DM_SHDUMP's fout.tsv for the next shader build" : "add it to the capture directory's fout.tsv and rebuild the shaders (or run with DM_SHDUMP)");
    }
}
static __unsafe_unretained id<MTLRenderPipelineState> pso_get(NvProg *pr, MTLRenderPassDescriptor *unused) {
    (void)unused;
    __unsafe_unretained NvShader *vs = pr->sh[0], *fs = pr->sh[1];
    if (!vs) { RED_ONCE(13, "program has no vertex shader (or it is not mapped)"); return nil; }
    pso_key k; pso_key_fill(&k, vs, fs, g_pass.cfmt, g_pass.dfmt, g_pass.sfmt, g_pass.samples, g_pso_lmap != NULL);
    if (g_pso_lmap) { memcpy(k.lmap, g_pso_lmap, 8); k.fsfn = (__bridge void *)g_pso_fsfn; }
    __unsafe_unretained id<MTLRenderPipelineState> cached = hm_get_id(&g_pso, &k);
    if (cached) return cached;
    if (hm_get_id(&g_pso_fail, &k)) return nil;
    id<MTLRenderPipelineState> ps;
    NSError *e = nil; uint64_t bt = bp_now();
    ps = g_pso_lmap ? nil : pso_pend_take(&k);
    if (ps) g_pp_taken++;
    else {
        if (g_pp_submit_mark != g_sub_serial) { g_pp_submit_mark = g_sub_serial; pso_predict_rest(); }   // First miss in this submission: first kick the later ones out to compile in parallel, then synchronously compile the one at hand
        MTLRenderPipelineDescriptor *d = pso_desc(&k, vs, fs, g_pso_fsfn, g_pso_lmap != NULL);
        ps = [g_dev newRenderPipelineStateWithDescriptor:d error:&e];
    }
    g_bp_pso_n++; g_bp_pso_ns += bp_now() - bt;
    if (!ps) { MLOG("[red] failed to create render pipeline (vertex %s, fragment %s): %s", vs->key, fs ? fs->key : "-", e.localizedDescription.UTF8String);
        if (fs) fout_note(fs, g_pass.cfmt);
        hm_put_id(&g_pso_fail, &k, (id)kCFBooleanTrue); return nil; }
    pso_skey sk; char shex[sizeof sk * 2 + 1]; pso_skey_from(&k, vs, fs, g_pso_lmap != NULL, g_pso_lmap ? &g_pso_fz : NULL, &sk); pso_skey_hex(&sk, shex);
    pso_record("R\t%s\n", shex);
    pso_user_record("R\t%s\n", shex);
    hm_put_id(&g_pso, &k, ps);
    return ps;
}
static NSString *warm_key(const char *s, size_t n) {
    size_t z = strnlen(s, n);
    return [[NSString alloc] initWithBytes:s length:z encoding:NSUTF8StringEncoding];
}
static NvShader *warm_shader(NSMutableDictionary<NSString *, NvShader *> *dict, NSString *key, int stage) {
    NvShader *sh = dict[key];
    if (!sh) { sh = shader_load(key, stage); if (sh) dict[key] = sh; }
    return sh;
}
static void warm_enqueue(WarmItem *item) {
    os_unfair_lock_lock(&g_warm_lock);
    [g_warm_items addObject:item];
    atomic_store_explicit(&g_warm_ready, 1, memory_order_release);
    os_unfair_lock_unlock(&g_warm_lock);
}
static void warm_worker(NSArray<NSString *> *paths) {
    @autoreleasepool {
        NSMutableDictionary<NSString *, NvShader *> *dict = [NSMutableDictionary dictionary];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (NSString *path in paths) {
            NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            if (!txt) { MLOG("[red] failed to read warm-up list: %s", path.UTF8String); continue; }
            for (NSString *line in [txt componentsSeparatedByString:@"\n"]) {
                if (!line.length || [line hasPrefix:@"#"] || [seen containsObject:line]) continue;
                [seen addObject:line];
                NSArray<NSString *> *c = [line componentsSeparatedByString:@"\t"];
                if (!c.count) continue;
                if ([c[0] isEqualToString:@"S"] && c.count >= 3) {
                    NSString *key = c[1]; NvShader *sh = warm_shader(dict, key, c[2].intValue);
                    if (!sh) continue;
                    WarmItem *item = [WarmItem new]; item->kind = 0; item->key = key; item->shader = sh;
                    warm_enqueue(item); g_warm_shaders++;
                } else if ([c[0] isEqualToString:@"R"] && c.count >= 2) {
                    pso_skey sk; if (pso_skey_parse(c[1].UTF8String, &sk)) continue;
                    NSString *vkey = warm_key(sk.vs, sizeof sk.vs), *fkey = warm_key(sk.fs, sizeof sk.fs);
                    NvShader *vs = vkey.length ? warm_shader(dict, vkey, sk.vs_stage) : nil;
                    NvShader *fs = fkey.length ? warm_shader(dict, fkey, sk.fs_stage) : nil;
                    if (!vs || (fkey.length && !fs)) continue;
                    id<MTLFunction> fsfn = nil;
                    if (sk.fz) {
                        if (sk.fz_desc.kind == 1 && fs) { int fx[32]; for (int i = 0; i < 32; i++) fx[i] = sk.fz_desc.fx[i]; fsfn = bf_fn(fs, fx, sk.fz_desc.fbmask, sk.k.lmap); }
                                                if (!fsfn) { g_warm_skip_fz++; continue; }
                    }
                    pso_key k = sk.k; k.vs = (__bridge void *)vs; k.fs = (__bridge void *)fs; k.fsfn = (__bridge void *)fsfn;
                    NSError *e = nil; id ps = [g_dev newRenderPipelineStateWithDescriptor:pso_desc(&k, vs, fs, fsfn, sk.merged) error:&e];
                    if (!ps) { MLOG("[red] background render pipeline creation failed: %s", e.localizedDescription.UTF8String); continue; }
                    WarmItem *item = [WarmItem new]; item->kind = 1; item->vs_key = vkey; item->fs_key = fkey; item->vs = vs; item->fs = fs; item->fsfn = fsfn; item->pso = k; item->object = ps;
                    warm_enqueue(item); g_warm_rps++;
                } else if ([c[0] isEqualToString:@"C"] && c.count >= 2) {
                    NSString *key = c[1]; if (!key.length) continue;
                    NvShader *cs = warm_shader(dict, key, 5);
                    if (!cs) continue;
                    NSError *e = nil; id ps = [g_dev newComputePipelineStateWithFunction:cs->fn error:&e];
                    if (!ps) { MLOG("[red] background compute pipeline creation failed: %s", e.localizedDescription.UTF8String); continue; }
                    WarmItem *item = [WarmItem new]; item->kind = 2; item->key = key; item->shader = cs; item->object = ps;
                    warm_enqueue(item); g_warm_cps++;
                }
            }
        }
        MLOG("pipeline warm-up complete: %llu shaders / %llu render pipelines (%llu specialized fragments skipped) / %llu compute pipelines, background time %.1f ms",
             g_warm_shaders, g_warm_rps, g_warm_skip_fz, g_warm_cps, (bp_now() - g_warm_t0) / 1e6);
    }
    atomic_store(&g_warm_running, 0);
}
// Wait for the background warm-up to finish (at most timeout_ms): returns how many milliseconds were actually waited, 0 if it is not running. On first install the system shader cache is fully cold; if warm-up is slower than the player entering a run,
// pipelines not yet warmed are compiled on the spot on the submit thread = in-run stutter; the loading screen on entering a run blocks the player anyway, so let it load a little longer (called where hle_nvn.c presents).
int mtl_warm_wait(int timeout_ms) { @autoreleasepool {
    if (!atomic_load(&g_warm_running)) return 0;
    uint64_t t0 = bp_now();
    while (atomic_load(&g_warm_running) && (bp_now() - t0) / 1000000ull < (uint64_t)timeout_ms) usleep(2000);
    return (int)((bp_now() - t0) / 1000000ull) + 1;
} }
static void warm_start(void) {
    if (g_warm_started++) return;
    const char *e = getenv("DM_PSO_MANIFEST");
    if (e && !strcmp(e, "off")) return;
    NSArray<NSString *> *paths;
    if (e && *e) {
        paths = @[@(e)];
    } else {
        NSString *seed = [g_shmap_path.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"pso_manifest.tsv"];
        NSMutableArray<NSString *> *all = [NSMutableArray arrayWithObject:seed];
        NSString *user = pso_user_path();
        if (user && [NSFileManager.defaultManager fileExistsAtPath:user]) [all addObject:user];
        if (![NSFileManager.defaultManager fileExistsAtPath:seed]) return;
        paths = all;
    }
    if (!g_warm_items) g_warm_items = [NSMutableArray array];
    g_warm_t0 = bp_now();
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);   // Not optional background work: it decides whether the pipelines are ready before the player enters a run
    dispatch_queue_t q = dispatch_queue_create("dm.nvn.pso-warm", attr);
    atomic_store(&g_warm_running, 1);
    dispatch_async(q, ^{ warm_worker(paths); });
}
static id<MTLDepthStencilState> dss_get(int has_depth, int has_stencil) {
    struct { ds_st ds; uint32_t vm[2], wm[2]; int hd, hs; } k;
    memset(&k, 0, sizeof k); k.ds = S.ds; memcpy(k.vm, S.st_vmask, 8); memcpy(k.wm, S.st_wmask, 8); k.hd = has_depth; k.hs = has_stencil;
    if (!g_dss.klen) g_dss.klen = sizeof k;
    id<MTLDepthStencilState> s = hm_get_id(&g_dss, &k);
    if (s) return s;
    MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
    if (has_depth && S.ds.dt) { d.depthCompareFunction = (MTLCompareFunction)(S.ds.df - 1); d.depthWriteEnabled = S.ds.dw; }
    if (has_stencil && S.ds.st) {
        MTLStencilDescriptor *f = [MTLStencilDescriptor new], *b = [MTLStencilDescriptor new];
        f.stencilCompareFunction = (MTLCompareFunction)(S.ds.sf_f - 1); f.stencilFailureOperation = (MTLStencilOperation)(S.ds.fail_f - 1);
        f.depthFailureOperation = (MTLStencilOperation)(S.ds.zfail_f - 1); f.depthStencilPassOperation = (MTLStencilOperation)(S.ds.zpass_f - 1);
        f.readMask = S.st_vmask[0]; f.writeMask = S.st_wmask[0];
        b.stencilCompareFunction = (MTLCompareFunction)(S.ds.sf_b - 1); b.stencilFailureOperation = (MTLStencilOperation)(S.ds.fail_b - 1);
        b.depthFailureOperation = (MTLStencilOperation)(S.ds.zfail_b - 1); b.depthStencilPassOperation = (MTLStencilOperation)(S.ds.zpass_b - 1);
        b.readMask = S.st_vmask[1]; b.writeMask = S.st_wmask[1];
        d.frontFaceStencil = f; d.backFaceStencil = b;
    }
    s = [g_dev newDepthStencilStateWithDescriptor:d];
    hm_put_id(&g_dss, &k, s);
    return s;
}
// Argument buffer: filled item by item per the B reflection (uniform slot r, separate texture / sampler slot r, storage buffer slot r, driver segments c0 / c2, c1, support_buffer)
// Unbound resources read 0: give all-zero dummy resources (NVN descriptors 0..255 are reserved for the driver; the game binding handle 0 means 'this slot is empty')
static uint64_t g_dummy_tex_rid[8][4], g_dummy_img_rid[8][4], g_dummy_tbuf_rid[4];
static id<MTLTexture> dummy_tex(int dtt, int dpf) {
    static __strong id<MTLTexture> cache[8][4];
    MTLTextureType tt = (MTLTextureType)dtt;
    MTLPixelFormat pf = dpf == NVN_DPF_DEPTH ? MTLPixelFormatDepth32Float : dpf == NVN_DPF_UINT ? MTLPixelFormatRGBA32Uint : dpf == NVN_DPF_SINT ? MTLPixelFormatRGBA32Sint : MTLPixelFormatRGBA8Unorm;
    id<MTLTexture> t = cache[dtt & 7][dpf & 3];
    if (t) return t;
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = tt; d.pixelFormat = pf; d.width = d.height = d.depth = 1; d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    t = [g_dev newTextureWithDescriptor:d];   // Shared storage is all zeros when newly created
    if (pf != MTLPixelFormatDepth32Float) { uint8_t z[64] = {0}; NSUInteger faces = tt == MTLTextureTypeCube || tt == MTLTextureTypeCubeArray ? 6 : 1;
        for (NSUInteger f = 0; f < faces; f++) [t replaceRegion:MTLRegionMake3D(0, 0, 0, 1, 1, 1) mipmapLevel:0 slice:f withBytes:z bytesPerRow:16 bytesPerImage:16]; }
    cache[dtt & 7][dpf & 3] = t; g_dummy_tex_rid[dtt & 7][dpf & 3] = t.gpuResourceID._impl; res_add(t);
    return t;
}
// Write sink for unbound image slots: kept separate from the dummy textures that read 0 (writes must not pollute them); one is shared per same type and same pixel class
static id<MTLTexture> dummy_img(int dtt, int dpf) {
    static __strong id<MTLTexture> cache[8][4];
    id<MTLTexture> t = cache[dtt & 7][dpf & 3]; if (t) return t;
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = (MTLTextureType)dtt; d.pixelFormat = dpf == NVN_DPF_UINT ? MTLPixelFormatRGBA32Uint : dpf == NVN_DPF_SINT ? MTLPixelFormatRGBA32Sint : MTLPixelFormatRGBA16Float;
    d.width = d.height = d.depth = 1; d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    t = [g_dev newTextureWithDescriptor:d]; cache[dtt & 7][dpf & 3] = t; g_dummy_img_rid[dtt & 7][dpf & 3] = t.gpuResourceID._impl; res_add(t); return t;
}
static id<MTLBuffer> dummy_buf(void);
static id<MTLTexture> dummy_tbuf(int dpf) {   // Unbound typed buffer: all zeros (pixel class matches the shader's texture_buffer<T>)
    static __strong id<MTLTexture> cache[4];
    id<MTLTexture> t = cache[dpf & 3]; if (t) return t;
    MTLPixelFormat pf = dpf == NVN_DPF_UINT ? MTLPixelFormatRGBA32Uint : dpf == NVN_DPF_SINT ? MTLPixelFormatRGBA32Sint : MTLPixelFormatRGBA32Float;
    id<MTLBuffer> b = dummy_buf();
    MTLTextureDescriptor *d = [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:pf width:b.length / 16 resourceOptions:b.resourceOptions usage:MTLTextureUsageShaderRead];
    t = [b newTextureWithDescriptor:d offset:0 bytesPerRow:b.length];
    cache[dpf & 3] = t; g_dummy_tbuf_rid[dpf & 3] = t.gpuResourceID._impl; return t;
}
static id<MTLSamplerState> dummy_samp(void) {
    static id<MTLSamplerState> s; if (!s) { MTLSamplerDescriptor *d = [MTLSamplerDescriptor new]; d.supportArgumentBuffers = YES; s = [g_dev newSamplerStateWithDescriptor:d]; }
    return s;
}
static uint64_t dummy_samp_rid(void) { static uint64_t rid; if (!rid) rid = dummy_samp().gpuResourceID._impl; return rid; }
static id<MTLBuffer> dummy_buf(void) { static id<MTLBuffer> b; if (!b) { b = [g_dev newBufferWithLength:64 << 10 options:MTLResourceStorageModeShared]; res_add(b); } return b; }
static uint64_t dummy_buf_gpu(void) { static uint64_t gpu; if (!gpu) gpu = dummy_buf().gpuAddress; return gpu; }
// useResource is idempotent for the same (resource, usage, stage) within one encoder: remember what this render encoder has already declared and skip repeats (a compute encoder is created anew for each dispatch, no dedup)
static uint8_t g_args_dirty[6] = {1, 1, 1, 1, 1, 1};
static int g_render_off;   // SetRenderEnable(false) is in effect (NVN reference: clears and draws are dropped while it is)
// SetRenderEnableConditional compares the 64-bit values at counters and counters + 16 (the NVN reference: two counter reports, one after the other) and
// renders if they are equal (mode 2) or not equal (mode 3). The host decides when it replays the command, from guest memory: counter reports other
// than samples passed are written in command order at replay (OP_REPORT_COUNTER), so a report earlier in the same submission is seen. A samples-passed
// result exists only after the GPU completes its submission: while one is pending on either value, rendering stays enabled (drawing too much is safe).
// Tears of the Kingdom clears each of its lighting buffers once per frame this way: conditional (not equal) clear, then a TIMESTAMP_TOP report into
// the same counters, whose counter half is 0 (the NVN reference: timestamp reports write 0 there), so the next conditional clear of the frame is
// skipped and the second lighting pass adds to the first. Clearing every time had wiped the first pass's light: the title mural stayed black.
// Samples-passed report destinations: address → fence of the latest submission that writes it (open addressing, one entry per distinct address,
// grown at half load; replay thread only). This was a ring of the last 256 reports: with more reports in flight a destination still pending had
// left the ring and its previous result was read (t_nvn 6c2b). Tears of the Kingdom makes about one report a frame (3 destinations), so it never
// hit that.
typedef struct { uint64_t addr, fence; } occ_ent;
static occ_ent *g_occ; static unsigned g_occ_cap, g_occ_n;
static occ_ent *occ_slot(uint64_t addr) {   // the entry of addr, or the empty slot where it goes
    unsigned m = g_occ_cap - 1, h = (unsigned)((addr >> 3) * 0x9E3779B97F4A7C15ull >> 40) & m;
    while (g_occ[h].addr && g_occ[h].addr != addr) h = (h + 1) & m;
    return &g_occ[h];
}
static void occ_note(uint64_t addr, uint64_t fence) {
    if (!addr) return;
    if (2 * (g_occ_n + 1) > g_occ_cap) {
        occ_ent *old = g_occ; unsigned oc = g_occ_cap; g_occ_cap = oc ? oc * 2 : 1024; g_occ = calloc(g_occ_cap, sizeof *g_occ); if (!g_occ) MDIE("occlusion table");
        for (unsigned i = 0; i < oc; i++) if (old[i].addr) *occ_slot(old[i].addr) = old[i];
        free(old);
    }
    occ_ent *e = occ_slot(addr); if (!e->addr) { e->addr = addr; g_occ_n++; }
    e->fence = fence;
}
static int occ_pending(uint64_t addr) {
    if (!g_occ_cap) return 0;
    pthread_mutex_lock(&g_mu); uint64_t done = g_done; pthread_mutex_unlock(&g_mu);
    const occ_ent *e = occ_slot(addr);
    return e->addr && e->fence > done;
}
static uint64_t g_args_reg_seen, g_args_dirty_seen;
static inline void args_dirty_all(void) { memset(g_args_dirty, 1, sizeof g_args_dirty); }
static inline void args_sync_dirty(void) {
    uint64_t reg = g_reg_gen, dirty = nvn_dirty_now();
    if (reg != g_args_reg_seen || dirty != g_args_dirty_seen) {
        g_args_reg_seen = reg; g_args_dirty_seen = dirty; args_dirty_all();
    }
}
static void bind_args(id<MTLCommandEncoder> en, int nvn_stage, int metal_vertex, id<MTLBuffer> ab, uint64_t gpu, size_t off, NSUInteger ai) {
    if (nvn_stage == 5) enc_c_args((id<MTLComputeCommandEncoder>)en, gpu, ai);
    else enc_r_args((id<MTLRenderCommandEncoder>)en, metal_vertex ? MTLRenderStageVertex : MTLRenderStageFragment, gpu, ai);
}
// Static constant buffers of route B: the Ryujinx support_buffer (layout in Ryujinx.Graphics.Shader/SupportBuffer.cs: alpha_test u32, is_bgra u32[8],
// viewport_inverse f4, viewport_size f4, frag_scale_count i32, render_scale f32[73]..., each field aligned to 16 bytes) and the all-0 driver constant segment (64 KB = the upper bound declared by shaders)
static id<MTLBuffer> support_buf(void) {
    static __strong id<MTLBuffer> b; if (b) return b;
    b = [g_dev newBufferWithLength:65536 options:MTLResourceStorageModeShared]; res_add(b);   // All 0 when newly created
    const int render_scale_off = 192;   // Measured MSL layout: alpha_test 0, is_bgra[8] 16, viewport_inverse 144, viewport_size 160, frag_scale_count 176, render_scale float4[73] 192 (take .x)
    for (int i = 0; i < 73; i++) *(float *)((uint8_t *)b.contents + render_scale_off + 16 * i) = 1.0f;
    return b;
}
static uint64_t support_gpu(void) { static uint64_t gpu; if (!gpu) gpu = support_buf().gpuAddress; return gpu; }
static id<MTLBuffer> zero_bank(void) { static __strong id<MTLBuffer> b; if (!b) { b = [g_dev newBufferWithLength:65536 options:MTLResourceStorageModeShared]; res_add(b); } return b; }
static uint64_t zero_bank_gpu(void) { static uint64_t gpu; if (!gpu) gpu = zero_bank().gpuAddress; return gpu; }
#if DM_NVN_M3
// De-duplicating resource declarations on the older API: repeated useResource for the same resource within one render encoder is idempotent, yet every newly encoded argument block declares all the resources it references once more -
// measured at 9.7 declarations per draw, of which 9.2 were already declared in this encoder, about 227 instructions per draw. Here it is recorded which resources have been declared with which usages in this pass (g_pass.serial, one-to-one with render encoders:
// the serial only increments before a render encoder is opened), and those already covered are skipped. When the table is full (more distinct resources in one pass than the table holds) nothing is recorded and declarations proceed as usual.
// Table entries do not retain resources: a declared resource is held by the encoder until the submission completes, so within one pass its address is not reused by another resource. Used only on the submission thread
enum { M3_USE_N = 1024 };
static struct { void *p; uint64_t pass; uint32_t u; } g_m3_use[M3_USE_N];
static inline int m3_use_seen(void *p, uint32_t u) {
    for (uint32_t h = (uint32_t)(((uintptr_t)p >> 4) * 0x9E3779B1u) >> 22, k = 0; k < M3_USE_N; k++, h = (h + 1) & (M3_USE_N - 1)) {
        if (g_m3_use[h].pass != g_pass.serial) { g_m3_use[h].p = p; g_m3_use[h].pass = g_pass.serial; g_m3_use[h].u = u; return 0; }
        if (g_m3_use[h].p == p) { if ((g_m3_use[h].u & u) == u) return 1; g_m3_use[h].u |= u; return 0; }
    }
    return 0;
}
#endif
// NVN driver constant segments as GLSLC-compiled shaders read them (0xA00 bytes, filled from the current bindings). c0: the storage buffer table
// (16 slots of {address 64 bits, size 32 bits}) at 0x110 (vertex), 0x310 (compute), 0x510 (pixel); for compute also the dispatch size {x, y, z}
// at 0x200 (gl_NumWorkGroups) and the uniform buffer table at 0x210 (16 × {address, size}, up to the storage table); for the graphics stages the
// largest point size at 0x610, to which a shader-written gl_PointSize is clamped (0x44fffe00 = 2047.9375 per MacNativeGames; nxnative uses
// 2047, Maxwell's limit; Metal clamps to its own). c2: the texture and sampler handle tables of the profile (nvn_c2). The compute and point-size
// words: nxnative 9579030 / ca7216c and MacNativeGames' driver_bank_fill (both MIT): Link's Awakening's light culling and Tears of the
// Kingdom's occlusion culling multiplied by a zero workgroup count, Odyssey's point sprites were clamped to size 0
static uint32_t g_dispatch_grid[3];   // the current dispatch's workgroup counts (dispatch)
static uint64_t g_disp_n, g_disp_shared;   // dispatches; those that went into an encoder already open (Metal 4)
static void drv_fill(uint8_t *d, int bank, int stage) {
    memset(d, 0, 0xA00);
    if (stage < 0 || stage >= 6) return;
    if (bank == 0) {
        int base = stage == 0 ? 0x110 : stage == 5 ? 0x310 : stage == 1 ? 0x510 : -1;
        if (base < 0) RED_ONCE(45, "stage %d shader reads driver segment c0, storage buffer table base address not measured", stage);
        else for (int r = 0; r < 16; r++) { uint64_t a = S.ssbo[stage][r].addr; uint32_t n = (uint32_t)S.ssbo[stage][r].size; memcpy(d + base + 16 * r, &a, 8); memcpy(d + base + 16 * r + 8, &n, 4); }
        if (stage == 5) {
            memcpy(d + 0x200, g_dispatch_grid, sizeof g_dispatch_grid);
            for (int r = 0; r < 16; r++) { uint64_t a = S.ubo[5][r].addr; uint32_t n = (uint32_t)S.ubo[5][r].size; memcpy(d + 0x210 + 16 * r, &a, 8); memcpy(d + 0x210 + 16 * r + 8, &n, 4); }
        } else { const float point_max = 2047.9375f; memcpy(d + 0x610, &point_max, sizeof point_max); }
    } else {
        for (int r = 0; r < g_c2.ntex && r < 128; r++) { uint32_t th = (uint32_t)S.tex[stage][r]; memcpy(d + g_c2.tex + 8 * r, &th, 4); }
        for (int r = 0; r < g_c2.nsamp && r < 128; r++) { uint32_t sh_ = (uint32_t)S.samp[stage][r]; memcpy(d + g_c2.samp + 8 * r, &sh_, 4); }
    }
}
// ---------- Inline uniform updates without ending the render pass (renaming; MacNativeGames' upd_log / upd_shadow, MIT; written anew here) ----------
// Tears of the Kingdom updates small uniform ranges between draws about 200 times a frame (nvnCommandBufferUpdateUniformBuffer). Each was a GPU copy,
// and a copy ends the render pass: a copy encoder in between and the pass reopened with every attachment loaded again (MacNativeGames counted ~80 copy
// encoders and ~23 split passes a frame). Now an update keeps its bytes in the update ring and is logged (upd_log). A draw binding a uniform range that
// logged updates overlap gets a private copy of that range (upd_shadow): its contents as of the submit call (the snapshot) with the logged updates
// applied in order, so draws before an update read the old bytes and draws after it the new ones. The logged updates reach memory, merged, at the end
// of the submission (mtl_sub_commit), before any copy or dispatch (blit(), dispatch) and before a draw that reads an updated range other than as a
// uniform buffer, or binds one without a snapshot (upd_guard_draw, before its render pass is opened). DM_NVN_UB_RENAME=0: a GPU copy per update
typedef struct { uint64_t lo, hi, seq; const uint8_t *data; } upd_ent;
// A log kept sorted by start, with the largest end up to each entry: overlaps are found by a binary search and a walk back over real overlaps (every
// uniform binding of a draw is looked up, and most overlap nothing). g_upd: updates not in memory yet (written by upd_flush); g_uh: every update of
// the submission, written or not (a private copy is the snapshot with all of them: the snapshot stays valid after a write, which only adds them)
typedef struct { upd_ent *e; uint64_t *maxhi; int n, cap; uint64_t lo, hi; } upd_list;
static upd_list g_upd = {.lo = UINT64_MAX}, g_uh = {.lo = UINT64_MAX};
static int *g_upd_idx, g_upd_icap; static uint64_t g_upd_seq, g_ren_pass = UINT64_MAX;
static uint64_t g_ren_updates, g_ren_shadows, g_ren_reuse, g_ren_flushes, g_ren_guard, g_ren_noshot, g_ren_unknown;
static int ub_rename_on(void) {
    static int v = -1;
    if (v < 0) { const char *e = getenv("DM_NVN_UB_RENAME"); v = !(e && !strcmp(e, "0")); if (!v) MLOG("DM_NVN_UB_RENAME=0: inline uniform updates copied on the GPU timeline (each ends the render pass)"); }
    return v;
}
static void upd_dirty_stages(uint64_t lo, uint64_t hi) {   // the argument blocks of stages binding an updated range are encoded again (they point at the old copy)
    for (int st = 0; st < 6; st++) for (int k = 0; k < 16; k++) { const p_bind_buf *u = &S.ubo[st][k]; if (u->addr && u->addr < hi && u->addr + (u->size ? u->size : 1) > lo) { g_args_dirty[st] = 1; break; } }
}
static void ul_add(upd_list *l, upd_ent v) {
    if (l->n == l->cap) { l->cap = l->cap ? l->cap * 2 : 256; l->e = realloc(l->e, (size_t)l->cap * sizeof *l->e); l->maxhi = realloc(l->maxhi, (size_t)l->cap * sizeof *l->maxhi);
                          if (!l->e || !l->maxhi) MDIE("uniform update log (%d entries)", l->cap); }
    int a = 0, b = l->n; while (a < b) { int m = (a + b) / 2; if (l->e[m].lo <= v.lo) a = m + 1; else b = m; }
    memmove(l->e + a + 1, l->e + a, (size_t)(l->n - a) * sizeof *l->e);
    l->e[a] = v; l->n++;
    for (int i = a; i < l->n; i++) { uint64_t pv = i ? l->maxhi[i - 1] : 0; l->maxhi[i] = MAX(l->e[i].hi, pv); }
    l->lo = MIN(l->lo, v.lo); l->hi = MAX(l->hi, v.hi);
}
static void ul_clear(upd_list *l) { l->n = 0; l->lo = UINT64_MAX; l->hi = 0; }
static uint64_t ul_seq(const upd_list *l, uint64_t lo, uint64_t hi) {   // the newest entry overlapping [lo, hi), 0 if none
    if (!l->n || hi <= l->lo || lo >= l->hi) return 0;
    int a = 0, b = l->n; while (a < b) { int m = (a + b) / 2; if (l->e[m].lo < hi) a = m + 1; else b = m; }   // [0, a) start below hi
    uint64_t last = 0;
    for (int i = a - 1; i >= 0 && l->maxhi[i] > lo; i--) if (l->e[i].hi > lo && l->e[i].seq > last) last = l->e[i].seq;
    return last;
}
static void ul_apply(const upd_list *l, uint64_t lo, uint8_t *out, uint64_t n) {   // the entries over out (= [lo, lo + n) before them), oldest first
    if (!l->n || lo + n <= l->lo || lo >= l->hi) return;
    uint64_t hi = lo + n; int a = 0, b = l->n, k = 0; while (a < b) { int m = (a + b) / 2; if (l->e[m].lo < hi) a = m + 1; else b = m; }
    if (g_upd_icap < l->n) { g_upd_icap = l->n * 2; g_upd_idx = realloc(g_upd_idx, (size_t)g_upd_icap * sizeof *g_upd_idx); if (!g_upd_idx) MDIE("uniform update log index"); }
    for (int i = a - 1; i >= 0 && l->maxhi[i] > lo; i--) if (l->e[i].hi > lo) g_upd_idx[k++] = i;
    for (int i = 1; i < k; i++) { int x = g_upd_idx[i], j = i - 1; while (j >= 0 && l->e[g_upd_idx[j]].seq > l->e[x].seq) { g_upd_idx[j + 1] = g_upd_idx[j]; j--; } g_upd_idx[j + 1] = x; }
    for (int i = 0; i < k; i++) { const upd_ent *e = &l->e[g_upd_idx[i]]; uint64_t s0 = MAX(lo, e->lo), e0 = MIN(hi, e->hi); memcpy(out + (s0 - lo), e->data + (s0 - e->lo), e0 - s0); }
}
static void upd_log(uint64_t lo, uint64_t hi, const uint8_t *data) {
    upd_ent v = {lo, hi, ++g_upd_seq, data};
    ul_add(&g_upd, v); ul_add(&g_uh, v); g_nupd = g_upd.n;
    g_ren_updates++; if (g_enc) g_ren_pass = g_pass.serial;
    upd_dirty_stages(lo, hi);
}
static void upd_sub_end(void) { ul_clear(&g_uh); }   // mtl_sub_commit, after upd_flush
static uint64_t upd_overlap_seq(uint64_t lo, uint64_t hi) { return ul_seq(&g_upd, lo, hi); }   // updates not in memory yet
static void upd_apply(uint64_t lo, uint8_t *out, uint64_t n) { ul_apply(&g_uh, lo, out, n); }   // over a snapshot: every update of the submission
// Private copies of updated uniform ranges, found through a direct-mapped index by (range, newest overlapping update): later draws binding the same
// range with no update in between share one
typedef struct { uint64_t lo, size, seq, gpu; void *buf; } ub_shadow;
enum { UB_SHADOW_N = 1024 };
static ub_shadow g_shadow[UB_SHADOW_N];
static uint64_t upd_shadow(uint64_t lo, uint64_t size, void **buf) {   // GPU address of [lo, lo + size) with the submission's updates, 0 to read as before (none overlaps, or memory holds them)
    uint64_t seq = size ? ul_seq(&g_uh, lo, lo + size) : 0;
    if (!seq) return 0;
    const us_ent *sc = us_find(lo, size);
    int pending = ul_seq(&g_upd, lo, lo + size) != 0;
    if (!sc && !pending) return 0;   // no snapshot (a GPU write of this submission reached it) and its updates written: memory on the GPU timeline is right
    uint64_t hh = (lo >> 4) ^ (lo >> 19) ^ (size * 0x9E3779B97F4A7C15ull); ub_shadow *e = &g_shadow[(hh ^ (hh >> 32)) & (UB_SHADOW_N - 1)];
    if (e->lo == lo && e->size == size && e->seq == seq && e->gpu) { *buf = e->buf; g_ren_reuse++; return e->gpu; }   // seq only grows: an entry of an earlier submission never matches
    id<MTLBuffer> ab; uint64_t pad = lo & 255; size_t off = arena_alloc((size_t)(size + pad), &ab) + (size_t)pad;   // same offset modulo 256 as the original (as the snapshots)
    uint8_t *cpu = (uint8_t *)ab.contents + off;
    if (sc) { memcpy(cpu, sc->cpu + (lo - sc->lo), (size_t)size); upd_apply(lo, cpu, size); }
    else {   // no snapshot and updates not written (upd_guard_draw could not write them first): memory with the pending writes, the updates among them
        g_ren_noshot++;
        if (!pend_read_x(lo, cpu, size, g_npend, 0)) { g_ren_unknown++; RED_ONCE(90, "renamed uniform update: range %#llx+%llu has no snapshot and a GPU write of unknown content (first case): its copy may be stale", (unsigned long long)lo, (unsigned long long)size); }
    }
    *e = (ub_shadow){lo, size, seq, ab.gpuAddress + off, (__bridge void *)ab}; *buf = e->buf; g_ren_shadows++;
    return e->gpu;
}
static void upd_flush(void) {   // the updates not in memory yet into memory on the GPU timeline (merged; ends a render pass if one is open)
    if (!g_upd.n || g_upd_flushing) return;
    g_upd_flushing = 1;
    upd_list *l = &g_upd;
    for (int i = 0; i < l->n;) {
        uint64_t lo = l->e[i].lo, hi = l->e[i].hi; int j = i + 1;
        for (; j < l->n && l->e[j].lo <= hi; j++) hi = MAX(hi, l->e[j].hi);   // overlapping or touching: covered whole by updates, one copy
        void *db; uint64_t dof;
        if (mtl_addr(lo, hi - lo, &db, &dof)) {
            id<MTLBuffer> sb; size_t so = arena_alloc((size_t)(hi - lo), &sb);
            ul_apply(l, lo, (uint8_t *)sb.contents + so, hi - lo);
            enc_b_copy_buffer(blit(), sb, so, (__bridge id<MTLBuffer>)db, dof, hi - lo);
        } else {   // touching updates in two pools: each on its own, oldest first (blit() orders them)
            int k0 = 0; if (g_upd_icap < j - i) { g_upd_icap = (j - i) * 2; g_upd_idx = realloc(g_upd_idx, (size_t)g_upd_icap * sizeof *g_upd_idx); }
            for (int q = i; q < j; q++) g_upd_idx[k0++] = q;
            for (int q = 1; q < k0; q++) { int x = g_upd_idx[q], r = q - 1; while (r >= 0 && l->e[g_upd_idx[r]].seq > l->e[x].seq) { g_upd_idx[r + 1] = g_upd_idx[r]; r--; } g_upd_idx[r + 1] = x; }
            for (int q = 0; q < k0; q++) { const upd_ent *e = &l->e[g_upd_idx[q]]; void *eb; uint64_t eo; __unsafe_unretained id<MTLBuffer> rb; size_t ro;
                if (!mtl_addr(e->lo, e->hi - e->lo, &eb, &eo)) MDIE("renamed uniform update %#llx+%#llx is no longer in a memory pool", (unsigned long long)e->lo, (unsigned long long)(e->hi - e->lo));
                ring_put(e->data, e->hi - e->lo, &rb, &ro); enc_b_copy_buffer(blit(), rb, ro, (__bridge id<MTLBuffer>)eb, eo, e->hi - e->lo); }
        }
        if (us_on()) us_gw_note(lo, hi - lo);   // a GPU write for the next submissions; the snapshot stays (private copies add every update to it)
        i = j;
    }
    ul_clear(l); g_nupd = 0; g_ren_flushes++;
    g_upd_flushing = 0;
}
static uint64_t g_ren_g[5];   // what made upd_guard_draw write the updates: index, vertex, storage buffer, buffer texture, uniform range without a snapshot
static void ren_report(uint64_t f) {   // every 300 frames
    static uint64_t p[12]; uint64_t c[12] = {g_ren_updates, g_ren_shadows, g_ren_reuse, g_ren_flushes, g_ren_guard, g_ren_noshot, g_ren_unknown, g_ren_g[0], g_ren_g[1], g_ren_g[2], g_ren_g[3], g_ren_g[4]};
    if (f % 300 || c[0] == p[0]) return;
    MLOG("renamed uniform updates up to frame %llu: %llu updates, %llu private copies (%llu shared), written to memory %llu times (%llu before a draw reading them otherwise: index %llu, vertex %llu, storage %llu, buffer texture %llu, no snapshot %llu); %llu copies without a snapshot, %llu of unknown content",
         (unsigned long long)f, (unsigned long long)(c[0] - p[0]), (unsigned long long)(c[1] - p[1]), (unsigned long long)(c[2] - p[2]), (unsigned long long)(c[3] - p[3]), (unsigned long long)(c[4] - p[4]),
         (unsigned long long)(c[7] - p[7]), (unsigned long long)(c[8] - p[8]), (unsigned long long)(c[9] - p[9]), (unsigned long long)(c[10] - p[10]), (unsigned long long)(c[11] - p[11]),
         (unsigned long long)(c[5] - p[5]), (unsigned long long)(c[6] - p[6]));
    memcpy(p, c, sizeof p);
}
// ---------- Draws that sample what their own pass draws (plan item 42; after tomodachi-native's attachment copies 4dbd30f / da08d11, MIT) ----------
// Tears of the Kingdom samples the level and layer a pass draws into in about 59 draws a frame in the prologue (full-screen passes at 1600x896,
// 800x448 and 400x224; DM_NVN_COUNTS). In a Metal render pass that is undefined; on the M5 such a draw reads the attachment as it was in memory
// before the pass: without the earlier draws of the pass (still in tile memory) and without a clear still pending when the pass opened. NVN defines
// only the case with a texture-invalidating barrier between the earlier draws and the read, which makes their results visible; without one, what
// the console shows is what the M5 reads: copying for every such draw (results of earlier draws and clears visible, tomodachi-native's choice for
// its game) put the prologue's shots outside the console's brightness range in two shots out of the video of the opening (s1300 / s1800: left
// third 39.0 against 44.2-54.5), the M5's own reads and the copies after a barrier inside it. So by default only a draw after such a barrier samples
// a copy: the pass ends there (the earlier draws stored), the whole texture is copied, the pass opens again loading it. DM_NVN_FBX=all copies for
// every such draw (a copy serves until a draw writes the attachment, a pending clear is applied first), DM_NVN_FBX=0 never. Every encoder starts
// with a full barrier, so one copy texture per shape is reused within a submission. Levels and layers the pass does not draw are not copied for
// (a downsample chain reading level k-1)
typedef struct { __strong id<MTLTexture> copy, src; uint64_t draw, sub; __strong id<MTLTexture> vsrc[4], view[4]; int nv; } fbx_ent;
static fbx_ent g_fbx[16]; static int g_nfbx;
static int g_fbx_act[9];   // this draw's: indices into g_fbx (g_fbx_nact of them, declared at rp_end), set when its pass is open (fbx_activate)
static int g_fbx_pend[9], g_fbx_npend;   // fbx_prepare's picks for the draw being prepared
static int g_fbx_on = -1;   // 0 off, 1 after a texture barrier (default), 2 all
static uint64_t g_fbx_bar_at;   // g_stat_draw at the last barrier that invalidates textures (NVN_BARRIER_INVALIDATE_TEXTURE_BIT)
static uint64_t g_fbx_copies, g_fbx_draws, g_fbx_refused;
void mtl_fbx_stats(uint64_t out[3]) { out[0] = g_fbx_draws; out[1] = g_fbx_copies; out[2] = g_fbx_refused; }
// The bound texture t, or the same view of it, on the copy of the attachment it is (nil: not this draw's attachment)
static id<MTLTexture> fbx_sub(id<MTLTexture> t, uint64_t *rid) {
    for (int a = 0; a < g_fbx_nact; a++) { fbx_ent *e = &g_fbx[g_fbx_act[a]];
        if (t == e->src) { *rid = e->copy.gpuResourceID._impl; return e->copy; }
        if (t.parentTexture != e->src) continue;
        for (int i = 0; i < e->nv; i++) if (e->vsrc[i] == t) { *rid = e->view[i].gpuResourceID._impl; return e->view[i]; }
        NSUInteger sl = t.textureType == MTLTextureTypeCube || t.textureType == MTLTextureTypeCubeArray ? t.arrayLength * 6 : t.textureType == MTLTextureType3D ? 1 : t.arrayLength;
        id<MTLTexture> v = [e->copy newTextureViewWithPixelFormat:t.pixelFormat textureType:t.textureType levels:NSMakeRange(t.parentRelativeLevel, t.mipmapLevelCount)
                                                           slices:NSMakeRange(t.textureType == MTLTextureType3D ? 0 : t.parentRelativeSlice, sl) swizzle:t.swizzle];
        if (!v) { RED_ONCE(96, "attachment copy: no view of the copy like the bound one (format %lu type %lu); the draw samples the attachment", (unsigned long)t.pixelFormat, (unsigned long)t.textureType); return nil; }
        int k = e->nv < 4 ? e->nv++ : 3; if (e->view[k]) defer_obj_unref(e->view[k]);
        e->vsrc[k] = t; e->view[k] = v; *rid = v.gpuResourceID._impl; return v;
    }
    return nil;
}
static int encode_args(id<MTLCommandEncoder> en, NvShader *sh, int nvn_stage, int metal_vertex) {
    if (!sh->ae) return 1;
    uint64_t slots[NVN_REFL_MAXB] = {0};
    args_sync_dirty();
    if (!passdump() && !g_args_dirty[nvn_stage] && sh->ab_buf && sh->ab_pass == g_pass.serial && nvn_stage != 5 && !sh->rf.ubo_addr) {   // ubo_addr: an address read from uniform data can change without a binding change
        bind_args(en, nvn_stage, metal_vertex, sh->ab_buf, sh->ab_gpu, sh->ab_off, sh->rf.abi);
        g_stat_args_reuse++;
        return 1;
    }
#if DM_NVN_M3
    // Older API: every resource a shader accesses indirectly through an argument block must have its usage declared on this encoder, so that the system knows its ordering dependency against other encoders (upload copies, other passes);
    // without the declaration a read-only texture gets out of order with the copy that writes it (measured before the move to Metal 4). Repeated declarations within one encoder are idempotent
    #define USE(r, u) do { id<MTLResource> r_ = (id<MTLResource>)(r); if (r_) { if (nvn_stage == 5) [(id<MTLComputeCommandEncoder>)en useResource:r_ usage:(u)]; else if (!m3_use_seen((__bridge void *)r_, (uint32_t)(u))) [(id<MTLRenderCommandEncoder>)en useResource:r_ usage:(u) stages:MTLRenderStageVertex | MTLRenderStageFragment]; } \
        if (__builtin_expect(g_res_check_on, 0)) res_check((r), sh->key, reg); } while (0)
    #define USE_SAMP(r, u) do { (void)(u); if (__builtin_expect(g_res_check_on, 0)) res_check((r), sh->key, reg); } while (0)   // samplers are not resources and need no declaration
#else
    #define USE(r, u) do { (void)(u); if (__builtin_expect(g_res_check_on, 0)) res_check((r), sh->key, reg); } while (0)
    #define USE_SAMP(r, u) USE(r, u)
#endif
    // DM_NVN_PASSDUMP: on the first new encode per pass per stage, records the shader key (K) and the actual source of each binding (B: UBO address / length / first 4 floats, texture ID and serial, or "dummy")
    static uint64_t bl_pass[6]; static int bl_all = -1; if (bl_all < 0) bl_all = getenv("DM_NVN_PASSDUMP_ALL") != NULL;   // Record on every new encode (otherwise only the first time per pass per stage)
    int bl = passdump() && (bl_all || bl_pass[nvn_stage] != g_stat_pass);
    if (bl) { bl_pass[nvn_stage] = g_stat_pass; PD("K %llu st%d key=%s nb=%d", g_stat_pass, nvn_stage, sh->key, sh->rf.nb); }
    pthread_mutex_lock(&g_rmu);   // The texture / sampler registration tables may be being grown or rewritten by the game thread
    for (int i = 0; i < sh->rf.nb; i++) {
        const nvn_rbind *b = &sh->rf.b[i];
        int reg = b->reg, aid = b->aid;
        if (b->kind == NVN_RB_CBUF) {
            const p_bind_buf *u = reg < 16 ? &S.ubo[nvn_stage][reg] : NULL;
            void *mb; uint64_t mo, gpu;
            if (!u || !u->addr || !mtl_gpu_addr(u->addr, 1, &mb, &mo, &gpu)) { RED_ONCE(16, "stage %d cb%d has no uniform buffer bound", nvn_stage, reg); continue; }
            use_rec("buf", u->addr, u->size, 0, NULL);
            if (bl) {
                PD("B %llu st%d cb reg%d addr=%#llx size=%llu pool=%#llx+%#llx f=%g,%g,%g,%g", g_stat_pass, nvn_stage, reg, (unsigned long long)u->addr, (unsigned long long)u->size,
                   (unsigned long long)(u->addr - mo), (unsigned long long)mo, ((float *)u->addr)[0], ((float *)u->addr)[1], ((float *)u->addr)[2], ((float *)u->addr)[3]);
                // DM_NVN_CBDUMP=directory: also saves the whole uniform block to disk as-is (F<frame>_p<pass>_st<stage>_cb<slot>_<address>.bin), for the ground-truth side to compare byte by byte by guest address
                static const char *cbd; static int cbd_init; if (!cbd_init) { cbd = getenv("DM_NVN_CBDUMP"); cbd_init = 1; }
                if (cbd) {
                    char p[1024]; snprintf(p, sizeof p, "%s/F%llu_p%llu_st%d_cb%d_%llx.bin", cbd, (unsigned long long)atomic_load(&g_cur_frame), g_stat_pass, nvn_stage, reg, (unsigned long long)u->addr);
                    FILE *f = fopen(p, "wb"); if (f) { fwrite((const void *)u->addr, 1, u->size, f); fclose(f); } else RED_ONCE(41, "CBDUMP cannot write %s", p);
                }
            }
            void *rb_ = NULL; uint64_t rg_ = g_nupd ? upd_shadow(u->addr, u->size, &rb_) : 0;   // logged updates over it: its private copy
            const us_ent *sc = rg_ ? NULL : us_find(u->addr, u->size);   // contents as of the submit call
            if (rg_) { gpu = rg_; mb = rb_; } else if (sc) { gpu = sc->gpu + (u->addr - sc->lo); mb = sc->buf; }
            slots[aid] = gpu;
            USE((__bridge id<MTLBuffer>)mb, MTLResourceUsageRead);
        } else if (b->kind == NVN_RB_SAMP || b->kind == NVN_RB_SAMPT) {   // SAMPT: the sampler part of a combined handle (texture ID | sampler ID << 20)
            int sid = reg < 128 ? (int)((b->kind == NVN_RB_SAMPT ? S.tex[nvn_stage][reg] : S.samp[nvn_stage][reg]) >> 20) : 0;
            __unsafe_unretained id<MTLSamplerState> ss = sid ? (__bridge id<MTLSamplerState>)samp_fast(sid) : nil;
            slots[aid] = sid && sid < g_nsreg && g_srid[sid] ? g_srid[sid] : dummy_samp_rid();
            USE_SAMP(ss ? ss : dummy_samp(), MTLResourceUsageRead);
            if (bl && sid > 0) { int ok = sid < g_nsreg && g_sreg_ok[sid]; samp_par sp = ok ? g_sreg[sid] : (samp_par){0};   // g_rmu is already held in this section
                if (ok) PD("B %llu st%d samp reg%d sid=%d mag=%d min=%d (0 nearest / 1 bilinear; 2–5 with mip) lod %g..%g bias %g wrap %d,%d", g_stat_pass, nvn_stage, reg, sid, (int)sp.magf, (int)sp.minf, sp.lod_min, sp.lod_max, sp.lod_bias, (int)sp.ws, (int)sp.wt); }
        } else if (b->kind == NVN_RB_TEX) {
            int tid = reg < 128 ? (int)(S.tex[nvn_stage][reg] & 0xfffff) : 0;
            void *tv = NULL; uint64_t trid = tid ? tex_fast_rid(tid, &tv) : 0; __unsafe_unretained id<MTLTexture> t = (__bridge id<MTLTexture>)tv;
            if (t && tid < g_ntreg) use_rec("tex", (uint64_t)g_treg[tid].t.mem, g_treg[tid].t.size, tid, &g_treg[tid].t);
            if (t && passdump() && tid < g_ntreg) PD("R %llu st%d ser=%llu", g_stat_pass, nvn_stage, g_treg[tid].t.serial);
            if (bl) PD("B %llu st%d tex reg%d tid=%d %s ser=%llu fmt=%lu %lux%lux%lu view_lv=%lu+%lu view_sl=%lu array=%lu target=%lu", g_stat_pass, nvn_stage, reg, tid, t ? "real" : "dummy", t && tid < g_ntreg ? g_treg[tid].t.serial : 0ull,
                       (unsigned long)t.pixelFormat, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.depth,
                       (unsigned long)(t.parentTexture ? t.parentRelativeLevel : 0), (unsigned long)t.mipmapLevelCount,
                       (unsigned long)(t.parentTexture ? t.parentRelativeSlice : 0), (unsigned long)t.arrayLength, (unsigned long)t.textureType);
            if (bl && t && tid < g_ntreg && g_treg[tid].t.mem && getenv("DM_NVN_TEXNZ")) {   // diagnostic: share of non-zero 8-byte words in the texture's guest storage
                const uint64_t *w = (const uint64_t *)(const void *)g_treg[tid].t.mem; size_t nw = MIN((size_t)g_treg[tid].t.size, (size_t)64 << 20) / 8, nz = 0;
                for (size_t i = 0; i < nw; i++) nz += w[i] != 0;
                PD("B %llu st%d tex reg%d storage %p size %#llx non-zero words %.4f", g_stat_pass, nvn_stage, reg, (const void *)g_treg[tid].t.mem, (unsigned long long)g_treg[tid].t.size, nw ? (double)nz / nw : 0.0);
                if (t.pixelFormat >= MTLPixelFormatBC1_RGBA && t.pixelFormat <= MTLPixelFormatBC7_RGBAUnorm_sRGB && t.textureType == MTLTextureType2D) {   // and of the Metal texture's level 0 (read back now, from a command buffer of its own)
                    size_t blk = t.pixelFormat <= MTLPixelFormatBC1_RGBA_sRGB || t.pixelFormat == MTLPixelFormatBC4_RUnorm || t.pixelFormat == MTLPixelFormatBC4_RSnorm ? 8 : 16;
                    NSUInteger tw = t.width, th = t.height; size_t row = (tw + 3) / 4 * blk, img = row * ((th + 3) / 4);
                    id<MTLBuffer> rb = [g_dev newBufferWithLength:img options:MTLResourceStorageModeShared];
                    id<MTLCommandBuffer> rc = q_cb(); id<MTLBlitCommandEncoder> be = [rc blitCommandEncoder];
                    [be copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(tw, th, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:img];
                    [be endEncoding]; [rc commit]; [rc waitUntilCompleted];
                    const uint64_t *mw = (const uint64_t *)rb.contents; size_t mn = img / 8, mz = 0; for (size_t i = 0; i < mn; i++) mz += mw[i] != 0;
                    PD("B %llu st%d tex reg%d Metal level 0 %lux%lu non-zero words %.4f", g_stat_pass, nvn_stage, reg, (unsigned long)tw, (unsigned long)th, mn ? (double)mz / mn : 0.0);
                }
            }
            if (t && t.textureType != (MTLTextureType)b->decl_tt) { uint64_t r2 = 0; id<MTLTexture> fv = tex_fit(tid, t, (MTLTextureType)b->decl_tt, &r2); if (fv) { t = fv; trid = r2; } }
            if (t && g_fbx_nact) { uint64_t r2 = 0; id<MTLTexture> c = fbx_sub(t, &r2); if (c) { t = c; trid = r2; } }   // the draw samples its own attachment: the copy
            if (!t) { t = dummy_tex(b->dtt, b->dpf); trid = g_dummy_tex_rid[b->dtt & 7][b->dpf & 3]; }
            slots[aid] = trid;
            USE(t, MTLResourceUsageRead);
        } else if (b->kind == NVN_RB_IMG) {   // Writable texture: NVN image slot r (BindImages) ↔ D3D u_r
            int tid = reg < 32 ? (int)(S.img[nvn_stage][reg] & 0xfffff) : 0;
            if (b->rw && tid && tid < g_ntreg) tex_gpu_write(&g_treg[tid].t);   // an image store writes the texture
            void *tv = NULL; uint64_t trid = tid ? tex_fast_rid(tid, &tv) : 0; __unsafe_unretained id<MTLTexture> t = (__bridge id<MTLTexture>)tv;
            if (passdump()) PD("W %llu st%d reg%d tid=%d %s ser=%llu", g_stat_pass, nvn_stage, reg, tid, t ? "real" : "dummy", t && tid < g_ntreg ? g_treg[tid].t.serial : 0ull);
            if (t && !(t.usage & MTLTextureUsageShaderWrite)) { RED_ONCE(32, "texture bound to an image slot lacks the shader-write usage (texture ID %d)", tid); t = nil; }
            if (!t) { t = dummy_img(b->dtt, b->dpf); trid = g_dummy_img_rid[b->dtt & 7][b->dpf & 3]; }   // Unbound: D3D semantics discard the write - write into a dedicated dummy texture so the set that reads 0 is not polluted
            slots[aid] = trid;
            USE(t, MTLResourceUsageRead | MTLResourceUsageWrite);
        } else if (b->kind == NVN_RB_TBUF) {   // Typed buffer: the buffer texture (target BUFFER) in texture slot r
            int tid = reg < 128 ? (int)(S.tex[nvn_stage][reg] & 0xfffff) : 0;
            void *tv = NULL; uint64_t trid = tid ? tex_fast_rid(tid, &tv) : 0; __unsafe_unretained id<MTLTexture> t = (__bridge id<MTLTexture>)tv;
            if (t && t.textureType != MTLTextureTypeTextureBuffer) { RED_ONCE(40, "texture bound to a typed buffer slot is not a buffer texture (texture ID %d type %lu)", tid, (unsigned long)t.textureType); t = nil; }
            if (bl) PD("B %llu st%d tbuf reg%d tid=%d %s ser=%llu", g_stat_pass, nvn_stage, reg, tid, t ? "real" : "dummy", t && tid < g_ntreg ? g_treg[tid].t.serial : 0ull);
            if (!t) { t = dummy_tbuf(b->dpf); trid = g_dummy_tbuf_rid[b->dpf & 3]; }
            slots[aid] = trid;
            USE(t, MTLResourceUsageRead);
        } else if (b->kind == NVN_RB_SBUFP || b->kind == NVN_RB_UBOP) {   // B: storage buffers / compute-stage uniforms are device pointers; the address is taken by NVN slot
            const p_bind_buf *u = reg < 16 ? (b->kind == NVN_RB_UBOP ? &S.ubo[nvn_stage][reg] : &S.ssbo[nvn_stage][reg]) : NULL;
            void *mb; uint64_t mo, gpu;
            if (b->kind == NVN_RB_SBUFP && b->rw && u && u->addr) us_drop(u->addr, u->size ? u->size : 1);   // the shader may write it
            const us_ent *sc = b->kind == NVN_RB_UBOP && u ? us_find(u->addr, u->size) : NULL;   // compute uniforms as of the submit call
            if (sc) { slots[aid] = sc->gpu + (u->addr - sc->lo); USE((__bridge id<MTLBuffer>)sc->buf, MTLResourceUsageRead); }
            else if (u && u->addr && mtl_gpu_addr(u->addr, u->size ? u->size : 1, &mb, &mo, &gpu)) { use_rec("buf", u->addr, u->size, 0, NULL); slots[aid] = gpu; USE((__bridge id<MTLBuffer>)mb, b->rw ? MTLResourceUsageRead | MTLResourceUsageWrite : MTLResourceUsageRead); }
            else { slots[aid] = dummy_buf_gpu(); USE(dummy_buf(), MTLResourceUsageRead); }
            if (bl) PD("B %llu st%d sbufp reg%d %s addr=%#llx size=%llu %s", g_stat_pass, nvn_stage, reg, u && u->addr ? "real" : "dummy", u ? (unsigned long long)u->addr : 0ull, u ? (unsigned long long)u->size : 0ull, b->rw ? "rw" : "ro");
        } else if (b->kind == NVN_RB_SBUFU) {   // B: a storage buffer the shader addresses from uniform slot r: {address u64, size u32} at byte off (the translator's cb slot r + 3)
            const p_bind_buf *u = reg < 16 ? &S.ubo[nvn_stage][reg] : NULL; uint8_t rec[12] = {0}; uint64_t sa = 0; uint32_t sn = 0;
            int ok = u && u->addr && b->off + 12 <= u->size && pend_read(u->addr + b->off, rec, 12);
            if (u && u->addr && !ok) RED_ONCE(77, "storage buffer address in uniform slot %d +%#x: a GPU copy earlier in the submission writes there, or it lies outside the binding (first case): dummy buffer", reg, b->off);
            if (ok) { memcpy(&sa, rec, 8); memcpy(&sn, rec + 8, 4); }
            if (sa && b->rw) us_drop(sa, sn ? sn : 65536);   // the shader may write it (no size given: 64 KiB)
            void *mb; uint64_t mo, gpu;
            if (sa && mtl_gpu_addr(sa, sn ? sn : 1, &mb, &mo, &gpu)) { use_rec("buf", sa, sn, 0, NULL); slots[aid] = gpu; USE((__bridge id<MTLBuffer>)mb, b->rw ? MTLResourceUsageRead | MTLResourceUsageWrite : MTLResourceUsageRead); }
            else { if (sa) RED_ONCE(78, "storage buffer address %#llx read from uniform slot %d +%#x is not in any memory pool (first case): dummy buffer", (unsigned long long)sa, reg, b->off);
                   slots[aid] = dummy_buf_gpu(); USE(dummy_buf(), MTLResourceUsageRead); }
            if (bl) PD("B %llu st%d sbufu ubo%d+%#x addr=%#llx size=%u %s", g_stat_pass, nvn_stage, reg, b->off, (unsigned long long)sa, sn, b->rw ? "rw" : "ro");
        } else if (b->kind == NVN_RB_C1) {      // B: the shader's own constant segment, built when the shader is fetched
            id<MTLBuffer> cb = sh->c1buf ? sh->c1buf : zero_bank();   // c1 has length 0 (600 of them in the whole library) yet the shader still declares it: reads 0
            slots[aid] = (sh->c1buf ? sh->c1_gpu : zero_bank_gpu()) + (sh->c1buf ? sh->c1off : 0);
            USE(cb, MTLResourceUsageRead);
        } else if (b->kind == NVN_RB_SUPPORT) {   // support_buffer: scale 1.0, BGRA swap 0, viewport transform not disabled (viewport fields are not read)
            slots[aid] = support_gpu();
            USE(support_buf(), MTLResourceUsageRead);
        } else if (b->kind == NVN_RB_DRV0 || b->kind == NVN_RB_DRV2) {
            // NVN driver constant segments: those proven unread by static analysis at packaging time are supplied as 0; those read are filled on the spot from the current bindings - c0 = storage buffer table (base + 0x10 r: address 64 bits, size 32 bits),
            // c2 = texture handle table and sampler handle table (bases from the game's nvn_c2, 8 bytes per slot), the values being the NVN handles the game gave at bind time; positions read outside the tables are registered at packaging time and reported a failure at load time
            int bank = b->kind == NVN_RB_DRV2 ? 2 : 0;
            if (!sh->rf.drv_read[bank]) { slots[aid] = zero_bank_gpu(); USE(zero_bank(), MTLResourceUsageRead); }
            else {
                id<MTLBuffer> db; size_t doff = arena_alloc(0xA00, &db); uint8_t *d = (uint8_t *)db.contents + doff;
                drv_fill(d, bank, nvn_stage);
                if (bank == 0) for (int r = 0; r < 16 && nvn_stage < 6; r++) { uint64_t a = S.ssbo[nvn_stage][r].addr; uint32_t n = (uint32_t)S.ssbo[nvn_stage][r].size;
                    if (a && n) us_drop(a, n); }   // reached through the table: whether the shader writes it is not known
                slots[aid] = g_cur_arena->gpu + doff;
                USE(db, MTLResourceUsageRead);
            }
        } else RED_ONCE(46, "binding kind %d not implemented", b->kind);
    }
    #undef USE
    #undef USE_SAMP
    pthread_mutex_unlock(&g_rmu);
    NSUInteger arg_len = sh->arg_len ? sh->arg_len : sh->ae.encodedLength;
    id<MTLBuffer> ab; size_t off = arena_alloc(arg_len, &ab);
    memcpy((uint8_t *)ab.contents + off, slots, arg_len);
    bind_args(en, nvn_stage, metal_vertex, ab, g_cur_arena->gpu + off, off, sh->rf.abi);
    sh->ab_buf = ab; sh->ab_gpu = g_cur_arena->gpu + off; sh->ab_off = off; sh->ab_pass = g_pass.serial; g_args_dirty[nvn_stage] = 0;
    g_stat_args_enc++;
    return 1;
}
static id<MTLBuffer> g_quad_ib; static uint64_t g_quad_gpu;
static RENC rp_begin(void);
// ---------- Pass lookahead: does this pass use depth / stencil ----------
// When opening a pass, scan forward from the op after the current draw, simulating the changes of depth-stencil state, up to where this pass must end (target reset, copy, compute dispatch -
// matching one-to-one the ops that end a pass in the replay). If no draw in between enables depth test / depth write / stencil test, this pass may leave the depth attachment unattached:
// not one byte of the depth content is touched, and on TBDR the load and store of the whole depth texture are saved (measured on a real device: a single-draw fullscreen pass takes half the GPU, with an extra D32S8 load and store attached).
// The scan follows real replay order across sub-list returns and across the remaining handles of this submission; end of submission = the pass must end. Undecidable cases such as a mid-pass clear or too-deep nesting always count as 'used'.
static const uint8_t *g_exec_next;   // The op following the current draw in the replay
static const uint8_t *g_ret[16]; static int g_ret_n;   // Call return stack of the replay (at OP_CALL the caller's next op is pushed)
static const uint64_t *g_rest; static int g_nrest;      // Handles in this submission still to be replayed after the current handle
void mtl_exec_rest(const uint64_t *h, int n) { g_rest = h; g_nrest = n; }
static uint64_t g_stat_ds_omit;      // Number of passes that attach less depth-stencil because the lookahead proved it unused (including stencil-only / depth-only)
static uint64_t g_stat_s_only, g_stat_d_only;   // Of those, the number of passes that attach only stencil / only depth
// Clear-only pass hoist (hoist_try): ops that were already executed early and must be skipped when replay reaches their original position (each group's SetRenderTargets and the clears in it).
// The exec loop, the store lookahead (sdx index) and the depth-stencil lookahead (ds_scan) all skip by it - otherwise the lookahead would take the clear at the original position as 'cleared again' and wrongly judge the early-cleared content redundant
#define HOIST_MAX 40   // At most 4 groups × (1 set-target op + 8 clears)
static const uint8_t *g_hoist_skip[HOIST_MAX]; static int g_hoist_n; static uint64_t g_hoist_groups;
static int hoist_skipped(const uint8_t *p) { for (int i = 0; i < g_hoist_n; i++) if (g_hoist_skip[i] == p) return 1; return 0; }
typedef struct { const uint8_t *p, *ret[8]; int ret_n, rest_i, bad; } fz_cursor;
static int fz_next(fz_cursor *c, const uint8_t **out, op_hdr *oh, const void **oa) {
    for (int guard = 0; guard < 1000000; guard++) {
        if (!c->p) return 0;
        op_hdr h; memcpy(&h, c->p, sizeof h); const void *a = c->p + 8;
        switch (h.op) {
            case OP_END:
                if (c->ret_n) c->p = c->ret[--c->ret_n];
                else if (c->rest_i < g_nrest) c->p = (const uint8_t *)g_rest[c->rest_i++];
                else { c->p = NULL; return 0; }
                continue;
            case OP_JUMP: memcpy(&c->p, a, 8); continue;
            case OP_CALL: { uint64_t t; memcpy(&t, a, 8); if (c->ret_n >= 8) { c->bad = 1; return 0; }
                c->ret[c->ret_n++] = c->p + h.size; c->p = (const uint8_t *)t; continue; }
            default: break;
        }
        const uint8_t *p = c->p; c->p += h.size;
        if (g_hoist_n && hoist_skipped(p)) continue;
        if (out) *out = p; if (oh) *oh = h; if (oa) *oa = a; return 1;
    }
    c->bad = 1; return 0;
}
// State of the readable-tile pass merge (merge B step 2): the earlier pass (phase 1) and the later pass (phase 2) share one render pass, and the attachments are the union
typedef struct {
    int active, phase, n1, nskip;
    int nreuse;
    const uint8_t *rt2_op, *reuse[8], *skip[12];
    p_set_rt rt1, rt2;                 // Logical targets of each of the two passes (R.rt is the union during the merge)
    int8_t p2map[8];                   // Logical color number of the later pass → physical attachment
    uint8_t lmap1[8], lmap2[8];        // Physical attachment → logical color number of this phase's draws (0xff = not written)
    uint8_t clr2[8], cd2f, cs2f; MTLClearColor cc2[8]; double cd2; uint32_t cs2;   // Clears at the start of the later pass (used as-is when the in-run dual render redraws)
    uint8_t wrote[8];                   // Physical attachments written by the later pass
    uint8_t cov2[8];                     // Physical attachments covered by the first draw of the later pass
} fuse_t;
static fuse_t g_fz; static uint64_t g_fz_n, g_fz_draws, g_fz_fallback;
typedef struct { int idx; p_draw dw; p_draw_idx di; p_scissor sc; int has_sc; void *S_; uint8_t pm[8]; } defer_snap;   // pm: group P target index → logical color number of this draw (identity for its own draws; a composed mapping for absorbed upstream groups)
typedef struct {
    int active, at_q, in_p, n, reason, reason_op, logged, reset_between; uint64_t born;   // born: creation serial (replay is ordered by it, not by slot)
    p_set_rt p_rt, q_rt;
    const uint8_t *p_end_op, *q_op;
    uint8_t clear_c[8], lmap[8];
    MTLClearColor cc[8];
    uint8_t clear_d, clear_s;
    double cd; uint32_t cs;
    uint64_t p_reads[512]; int nreads, p_dw, p_st;
    defer_snap snap[64];
} defer_t;
static defer_t g_defer_slots[4];
static defer_t *g_defer_cur = &g_defer_slots[0];
#define g_defer (*g_defer_cur)
static int sub_eq(const p_set_rt *a, int ka, const p_set_rt *b, int kb);
static uint64_t g_defer_n, g_defer_draws, g_defer_fallbacks;
static const uint8_t *g_defer_pend;   // The P-range end op of the group that is in its P range (NULL if none): the exec loop compares each op against just this one pointer
static int g_defer_nact, g_defer_natq;   // Number of active groups, number of groups that reached Q and await replay (the hot path only looks at the counts, no per-slot scan)
static int g_defer_ab = -1, g_defer_ab_on;
static void draw(const p_draw *dw, const p_draw_idx *di);
static int defer_has_in_p(void) { return g_defer_pend != NULL; }
static int defer_has_active(void) { return g_defer_nact > 0; }
static int defer_slot_free(void) { for (int i = 0; i < 4; i++) if (!g_defer_slots[i].active) return i; return -1; }
static int defer_same_q_depth(const defer_t *a, const p_set_rt *q) {
    if (!a->q_rt.depth || !q->depth) return 1;
    return sub_eq(&a->q_rt, 8, q, 8);
}
static int defer_next(int at_q_only, uint64_t after) {   // Slot number of the next active group (smallest creation serial that is > after); returns −1 if none
    int best = -1; for (int i = 0; i < 4; i++) { const defer_t *d = &g_defer_slots[i]; if (!d->active || (at_q_only && !d->at_q) || d->born <= after) continue; if (best < 0 || d->born < g_defer_slots[best].born) best = i; }
    return best;
}
static void defer_release_one(defer_t *d) { if (d->active) { g_defer_nact--; if (d->at_q) g_defer_natq--; if (d->in_p) g_defer_pend = NULL; } for (int i = 0; i < d->n; i++) free(d->snap[i].S_); memset(d, 0, sizeof *d); }
static void defer_clear_all(void) { for (int i = 0; i < 4; i++) defer_release_one(&g_defer_slots[i]); g_defer_nact = g_defer_natq = 0; g_defer_pend = NULL; }
static int hoist_take(const uint8_t *p) { for (int i = 0; i < g_hoist_n; i++) if (g_hoist_skip[i] == p) { g_hoist_skip[i] = g_hoist_skip[--g_hoist_n]; return 1; } return 0; }
enum { DS_FREE = 0, DS_USED = 1, DS_RET = 2 };
static int g_ds_why; static int g_ds_scanned; static int g_ds_need;   // g_ds_need: need accumulated during the scan, 1 depth 2 stencil   // Diagnostics: the opcode that triggered the 'used' verdict (for a draw, records 1000 + dt*100 + dw*10 + st), and the number of ops scanned
static int ds_scan(const uint8_t *p, ds_st *ds, int depth) {
    for (int guard = 0; guard < 1000000; guard++) {
        op_hdr h; memcpy(&h, p, sizeof h);
        const void *a = p + 8; g_ds_scanned++;
        if (g_hoist_n && hoist_skipped(p)) { p += h.size; continue; }   // Clear pass already executed early
        switch (h.op) {
            case OP_END: return DS_RET;
            case OP_JUMP: { const uint8_t *t; memcpy(&t, a, 8); p = t; continue; }
            case OP_CALL: { uint64_t t; memcpy(&t, a, 8); if (depth >= 8) return DS_USED;
                int r = ds_scan((const uint8_t *)t, ds, depth + 1); if (r != DS_RET) return r; break; }
            case OP_UPDATE_UB: if (ub_rename_on()) break; return DS_FREE;   // renamed: the pass goes on past it
            case OP_SET_RT: case OP_COPY_B2B: case OP_COPY_B2T: case OP_COPY_T2B: case OP_COPY_T2T: case OP_CLEAR_TEX: case OP_DISPATCH: return DS_FREE;
            case OP_CLEAR_COLOR: case OP_CLEAR_DS: g_ds_why = h.op; return DS_USED;
            case OP_BIND_STATE: { const p_bind_state *b = a; if (b->kind == 5) memcpy(ds, b->bytes, sizeof *ds); break; }
            case OP_DRAW: case OP_DRAW_IDX:   // Depth test / write → depth needed; stencil test → stencil needed; can stop once both are needed
                g_ds_need |= (ds->dt || ds->dw ? 1 : 0) | (ds->st ? 2 : 0);
                if (g_ds_need == 3) { g_ds_why = 1000 + ds->dt * 100 + ds->dw * 10 + ds->st; return DS_USED; } break;
            default: break;
        }
        p += h.size;
    }
    return DS_USED;
}
// Store lookahead decision (command by command, in real replay order):
//   Redundant: after being set as an attachment again and before any draw, it is cleared in full (color: all four channels of that index written; depth: depth clear; stencil: all 8 stencil bits cleared. Depth and stencil are decided separately and their write-back is set separately)
//   Needed: at a draw / dispatch it is bound to a texture or image slot of any stage (including ones already bound when the scan starts); used as copy source / copy destination / texture-clear target; drawn before cleared after becoming an attachment again (load)
// Different levels / layers of the same texture are decided separately (a downsample chain writes level k and reads level k−1); a sampler binding counts as a read of the whole texture (conservative)
static const uint8_t *g_exec_cur;   // The op currently being replayed (inclusive)
static void sd_need(sd_att *t, int why) { if (!t->state) { t->state = 1; t->why = (uint8_t)why; } }   // why: 1 a draw reads it as a texture 2 as an attachment, drawn before cleared 3 copy 4 texture clear 5 scanned to the end undecided 6 no start point / index unavailable
static int sdx_decide(uint8_t st[9]);   // Store lookahead decision (for the index see mtl_sub_index)
static void sd_finish(void) {
    if (!g_nsd) return;
    if (!tbdr_on()) {   // All optimizations off: always write back
        for (int i = 0; i < g_nsd; i++) { sd_att *t = &g_sd[i];
            enc_r_store(g_enc, t->depth, MTLStoreActionStore, (NSUInteger)t->idx); }
        g_nsd = 0; return; }
    uint8_t nst[9];
    if (sdx_decide(nst)) { for (int i = 0; i < g_nsd; i++) if (nst[i] == 2) g_sd[i].state = 2; else sd_need(&g_sd[i], nst[i] >> 2); }
    else for (int i = 0; i < g_nsd; i++) sd_need(&g_sd[i], 6);   // Pass ended outside the list / index unavailable: always write back
    for (int i = 0; i < g_nsd; i++) {
        sd_att *t = &g_sd[i]; int udc_dead = udc_on() && t->load && !t->wrote;
        // A color attachment written in the same pass as the window texture does not enter the ledger: it is a link in the present chain, not a transient attachment that is 'reset every frame before use'.
        // The in-run 'upscale' pass writes two textures at once - scene texture + window texture - and the UI composite was merged into the same pass, so in-run nobody reads back the scene texture; as soon as the game stops drawing 3D (loading screen)
        // a separate composite pass samples it afterwards instead. 'About to enter the loading screen' is only known after the previous frame was submitted, so prediction cannot stop it: on iPad true fullscreen every install hits it once on the first act change
        // (the 2732×2048 attachment of frame N was not written back and is sampled for 4 consecutive frames starting at frame N+1; the key is permanently disabled). At the iPhone aspect ratio the same-size key already sees a reader during the trial period and is silently disabled.
        int xv_win = 0; for (int k = 0; k < R.rt.n && k < 8; k++) if (R.rt.color[k] && xv_present(R.rt.color[k]->serial)) xv_win = 1;
        uint64_t xtag = 0; int xvcand = xv_on() && !xv_win && t->depth == 0 && t->state != 2 && t->why == 5 && xv_first_good(t->ser, t->lv, t->sl) && !xv_present(t->ser)
                                        && !xv_disabled(xtag = xv_tag_pass(R.rt.color[t->idx], t->lv, t->idx, &R.rt));
        int xvdead = xvcand && xv_trial_get(xtag, 0) >= XV_TRIAL;   // Only after the trial period is the write-back really skipped
        if (xvcand && !xvdead) xv_set(t->ser, t->lv, t->sl, XV_PROBE, xtag);   // Trial period: write back as usual, only track the next touch
        int dead = t->state == 2 || udc_dead || xvdead; MTLStoreAction sa = dead ? MTLStoreActionDontCare : MTLStoreActionStore;
        if (xvdead) { xv_set(t->ser, t->lv, t->sl, XV_INVALID, xtag); g_xv_dc++; }
        enc_r_store(g_enc, t->depth, sa, (NSUInteger)t->idx);
        g_sd_n_all++; if (dead) { g_sd_n_dead++; g_sd_dead_bytes += t->bytes; g_bw_store -= t->bytes; if (udc_dead) g_udc_saved_bytes += t->bytes; }
        if (!t->state) t->why = 5;
        PD("Z %llu %s ser=%llu lv%u sl%u %s why=%d by=%s slot=%d", g_stat_pass, t->depth == 1 ? "d" : t->depth == 2 ? "s" : "c", (unsigned long long)t->ser, t->lv, t->sl, xvdead ? "dontcare-xv" : dead ? "dontcare" : "store", dead ? 0 : t->why, t->why == 1 && t->wkey ? t->wkey : "-", t->wslot);
        if (udc_on()) PD("U %llu %s ser=%llu lv%u sl%u runtime=%s reason=%s state=%d load=%d", g_stat_pass, t->depth == 1 ? "d" : t->depth == 2 ? "s" : "c", (unsigned long long)t->ser, t->lv, t->sl, t->wrote ? "wrote" : "not-written", t->wwhy == 1 ? "image-write" : t->wwhy == 2 ? "color-write-mask" : t->wwhy == 3 ? "fragment-output" : t->wwhy == 4 ? "depth-write" : t->wwhy == 5 ? "stencil-write" : "none", t->state, t->load);
    }
    g_nsd = 0;
}
// Continue scanning in real replay order: current list -> callers at each level (return stack from the top down) -> remaining handles of this submit; the render pass necessarily ends when the submit ends (rp_flush before commit)
// Coverage proof (holds only if all are satisfied; anything unrecognized is treated as not holding):
//   Shader: the vertex position xyz is taken as-is from one vertex attribute, w is 1 or the same attribute's .w (dmsh_build raster_facts); the fragment does not discard, does not write sample_mask, and writes this color index
//   State: this attachment has no blending, a full write mask, no alpha-to-coverage, fill mode, no depth test (or ALWAYS), no stencil test, single sample, not 3D
//   Vertices: non-indexed or 16 / 32-bit indexed draws, with indices and positions both read from CPU-visible pool memory; the scissor / viewport / geometry / winding / depth clipping decisions are in nvn_cover.h (pure functions, with unit tests)
// Read out attribute a of all vertices of this draw (non-indexed or 16 / 32-bit indexed; vertex number = first + k or index value + base_vertex), with missing components filled with 0 / 1 per the fetch rules.
// Returns 0 on success, a reason code on failure (6 vertex count / index type, 7 attribute index, 8 format / stream, 9 out of bounds, 10 address)
static int attr_read(int a, const p_draw *dw, const p_draw_idx *di, float P[64][4]) {
    int n = dw ? dw->count : di->count;
    if (n < 1 || n > 64 || (dw && dw->first < 0) || (di && (di->itype < 1 || di->itype > 2))) return 6;
    if (a < 0 || a >= S.nattr || S.attr[a].stream >= 16) return 7;
    va_st at = S.attr[a]; vs_st sm = S.stream[at.stream]; NVNbufferRange vb = S.vbuf[at.stream];
    MTLVertexFormat vf = vfmt(at.fmt); int nc = vf == MTLVertexFormatFloat2 ? 2 : vf == MTLVertexFormatFloat3 ? 3 : vf == MTLVertexFormatFloat4 ? 4 : 0;
    if (!nc || !sm.stride || sm.divisor || !vb.address) return 8;
    const uint8_t *ib = NULL; int isz = di ? (di->itype == 1 ? 2 : 4) : 0;
    if (di) { void *m; uint64_t o; if (!mtl_addr(di->ibuf, (uint64_t)n * isz, &m, &o) || !(ib = [(__bridge id<MTLBuffer>)m contents])) return 10; ib += o; }
    for (int k = 0; k < n; k++) {
        int64_t vid = dw ? (int64_t)dw->first + k : (isz == 2 ? (int64_t)((const uint16_t *)ib)[k] : (int64_t)((const uint32_t *)ib)[k]) + di->base_vertex;
        uint64_t off = (uint64_t)vid * sm.stride + at.offset;
        if (vid < 0 || off + 4 * nc > vb.size) return 9;
        void *mb; uint64_t mo; const uint8_t *base;
        if (!mtl_addr(vb.address + off, 4 * nc, &mb, &mo) || !(base = [(__bridge id<MTLBuffer>)mb contents])) return 10;
        float v[4] = {0, 0, 0, 1}; memcpy(v, base + mo, 4 * nc); memcpy(P[k], v, sizeof v);
    }
    return 0;
}
static int first_draw_covers(int i, id<MTLTexture> t, NSUInteger level) {
    const p_draw *dw = g_fd_dw; const p_draw_idx *di = g_fd_di;
    int n = dw ? dw->count : di->count, prim = dw ? dw->prim : di->prim;
    __unsafe_unretained NvProg *pr = S.prog ? prog_get(S.prog) : nil; if (!pr) return g_fd_why = 1, 0;
    NvShader *vs = pr->sh[0], *fs = pr->sh[1];
    if (!vs || !fs || vs->rf.pos_attr < 0 || fs->rf.may_discard || alpha_on() || fs->rf.writes_smask || !(fs->rf.color_mask >> i & 1)) return g_fd_why = 2, 0;
    if (!t || t.sampleCount != 1 || t.textureType == MTLTextureType3D) return g_fd_why = 3, 0;
    if ((S.color.blend_en >> i & 1) || ((S.chmask.mask >> (4 * i)) & 0xf) != 0xf || S.ms.a2c || S.poly.mode != NVN_POLYGON_MODE_FILL) return g_fd_why = 4, 0;
    if (R.rt.depth && ((S.ds.dt && S.ds.df != NVN_DEPTH_FUNC_ALWAYS) || S.ds.st)) return g_fd_why = 5, 0;
    if (n < 3 || n > 64) return g_fd_why = 6, 0;
    float P[64][4]; int why = attr_read(vs->rf.pos_attr, dw, di, P);
    if (why) return g_fd_why = why, 0;
    if (vs->rf.pos_w1) for (int k = 0; k < n; k++) P[k][3] = 1.0f;   // Position w is the constant 1 (the attribute's .w is not taken)
    int sc[4] = {R.sc.x, R.sc.y, R.sc.w, R.sc.h}; float vp[4] = {S.vp[0][0], S.vp[0][1], S.vp[0][2], S.vp[0][3]};
    g_fd_why = 11;
    return nvn_cover((const float (*)[4])P, n, prim, (int)S.poly.cull, S.poly.front == NVN_FRONT_FACE_CCW,
                     S.has_vp, vp, R.has_sc, sc, (long)MAX(t.width >> level, 1), (long)MAX(t.height >> level, 1));
}
// A deferred binding record (hle_nvn.c BindTexturesDeferred) reads its handles from where the game keeps them, each time the record is read (nxnative)
static inline void bh_fresh(const p_bind_handles *b) {
    if (b->defer && b->src && b->n > 0 && b->n <= 32) memcpy((void *)b->h, (const void *)(uintptr_t)b->src, 8 * (size_t)b->n);
}

static int state_op(uint32_t op, const void *a) {
    switch (op) {
        case OP_SCISSOR: R.sc = *(const p_scissor *)a; R.has_sc = 1; break;
        case OP_BIND_PROGRAM: { const p_bind_program *b = a; const prog_t *np = prog_bind(S.prog, b->prog, b->stages); if (np != S.prog) { S.prog = np; g_pso_dirty = 1; args_dirty_all(); } break; }
        case OP_BIND_STATE: {
            const p_bind_state *b = a; void *dst = NULL; size_t n = 0;
            blend_st bs;
            switch (b->kind) {
                case 0: memcpy(&bs, b->bytes, sizeof bs); dst = &S.blend[bs.target]; n = sizeof bs; break;
                case 1: dst = &S.color; n = sizeof S.color; break;
                case 2: dst = &S.chmask; n = sizeof S.chmask; break;
                case 3: dst = &S.ms; n = sizeof S.ms; break;
                case 4: dst = &S.poly; n = sizeof S.poly; break;
                case 5: dst = &S.ds; n = sizeof S.ds; break;
                case 6: dst = &S.alpha_ref; n = sizeof S.alpha_ref; break;
            }
            if (dst && memcmp(dst, b->bytes, n)) { memcpy(dst, b->bytes, n); if (b->kind == 5) g_dss_dirty = 1; else g_pso_dirty = 1; }
            break;
        }
        case OP_BIND_VATTR: { const p_bind_vattr *b = a; if (S.nattr != b->n || memcmp(S.attr, b->st, 4 * b->n)) { memcpy(S.attr, b->st, 4 * b->n); S.nattr = b->n; g_pso_dirty = 1; } break; }
        case OP_BIND_VSTREAM: { const p_bind_vstream *b = a; if (S.nstream != b->n || memcmp(S.stream, b->st, 8 * b->n)) { memcpy(S.stream, b->st, 8 * b->n); S.nstream = b->n; g_pso_dirty = 1; } break; }
        case OP_BIND_VBUF: { const p_bind_vbuf *b = a; memcpy(&S.vbuf[b->first], b->r, sizeof *b->r * b->n); break; }
        case OP_BIND_UBO: { const p_bind_buf *b = a; gw_note(b, 0); PD("b bind_ub st%d r%d addr=%#llx size=%llu", b->stage, b->index, (unsigned long long)b->addr, (unsigned long long)b->size); if (b->stage < 6 && b->index < 16 && memcmp(&S.ubo[b->stage][b->index], b, sizeof *b)) { S.ubo[b->stage][b->index] = *b; g_args_dirty[b->stage] = 1; } break; }
        case OP_BIND_SSBO: { const p_bind_buf *b = a; gw_note(b, 1); if (b->stage < 6 && b->index < 16 && memcmp(&S.ssbo[b->stage][b->index], b, sizeof *b)) { S.ssbo[b->stage][b->index] = *b; g_args_dirty[b->stage] = 1; } break; }
        case OP_BIND_TEX: { const p_bind_handles *b = a; bh_fresh(b); if (b->stage < 6 && b->first + b->n <= 128 && memcmp(&S.tex[b->stage][b->first], b->h, 8 * b->n)) { memcpy(&S.tex[b->stage][b->first], b->h, 8 * b->n); g_args_dirty[b->stage] = 1; } break; }
        case OP_BIND_SAMP: { const p_bind_handles *b = a; bh_fresh(b); if (b->stage < 6 && b->first + b->n <= 128 && memcmp(&S.samp[b->stage][b->first], b->h, 8 * b->n)) { memcpy(&S.samp[b->stage][b->first], b->h, 8 * b->n); g_args_dirty[b->stage] = 1; } break; }
        case OP_BIND_IMG: { const p_bind_handles *b = a; bh_fresh(b); if (b->stage < 6 && b->first >= 0 && b->first + b->n <= 32) { if (memcmp(&S.img[b->stage][b->first], b->h, 8 * b->n)) { memcpy(&S.img[b->stage][b->first], b->h, 8 * b->n); g_args_dirty[b->stage] = 1; } } else RED_ONCE(31, "image slot out of range stage %d first %d count %d", b->stage, b->first, b->n); break; }
        case OP_STENCIL: {
            const p_stencil *b = a;
            if (b->which != 2) g_dss_dirty = 1;
            for (int f = 0; f < 2; f++) if (b->face & (1 << f)) { if (b->which == 0) S.st_vmask[f] = b->value_mask; else if (b->which == 1) S.st_wmask[f] = b->mask; else S.st_ref[f] = b->ref; }
            break;
        }
        case OP_POLY_OFFSET: S.po = *(const p_poly_offset *)a; break;
        case OP_VIEWPORTS: { const p_viewports *b = a; for (int i = 0; i < b->n; i++) memcpy(S.vp[b->first + i], b->v[i], 16); S.has_vp = 1; break; }
        case OP_DEPTH_RANGE: { const p_depth_range *b = a; S.dr[0] = b->n; S.dr[1] = b->f; break; }
        case OP_BLEND_COLOR: memcpy(S.blend_color, ((const p_blend_color *)a)->rgba, 16); break;
        case OP_DEPTH_CLAMP: S.depth_clamp = ((const p_depth_clamp *)a)->enable; break;
        case OP_PRIM_RESTART: { const p_prim_restart *r = a; S.restart_set = 1; S.restart_en = r->enable; S.restart_idx = r->index; break; }
        case OP_COPY_STRIDE: S.copy_stride = ((const p_copy_stride *)a)->stride; break;
        case OP_COPY_IMAGE_STRIDE: S.copy_image_stride = ((const p_copy_stride *)a)->stride; break;
        default: return 0;
    }
    return 1;
}

static void rt_sub(const p_set_rt *r, int k, uint64_t *ser, int *lv, int *sl);

// Prediction for parallel precompilation (see the note before pso_get): scan from after the current operation to the end of this submit, replaying only state; at a draw, compute the pipeline key from "the state at that time + that render pass's attachment formats" and dispatch those not yet built to the background.
// Whether a render pass actually attaches depth / stencil is only decided at replay (depth-only / stencil-only / neither attached are omitted), so one key is computed for each possible attach mode -- guessing too many only means wasted background compiles and does not affect the result.
static void pso_predict_rest(void) {
    if (!g_exec_next) return;
    static typeof(S) Ssave; memcpy(&Ssave, &S, sizeof S);
    p_scissor sc0 = R.sc; int hsc0 = R.has_sc;   // state_op sets the scissor too: the draw that asked for the prediction used the last one walked over
    int pso_dirty = g_pso_dirty, dss_dirty = g_dss_dirty;
    uint32_t cf[8]; memcpy(cf, g_pass.cfmt, sizeof cf); uint32_t df = g_pass.dfmt, sf = g_pass.sfmt, samples = g_pass.samples, dfull = df, sfull = sf; int kicked0 = (int)g_pp_kicked, draws = 0;
    fz_cursor cur = {.p = g_exec_next};
    // Collect them all first, then dispatch: keys for "attachments attached as-is" go first (most likely to be used), the other attach modes after -- background concurrency is limited, and what is dispatched first is compiled first
    enum { QN = 160 }; static struct { pso_key k; void *vs, *fs; } qa[QN], qb[QN]; int na = 0, nb = 0;
    for (int guard = 0; guard < 200000 && na < QN; guard++) {
        const uint8_t *q; op_hdr hq; const void *aq;
        if (!fz_next(&cur, &q, &hq, &aq)) break;
        if (hq.op == OP_SET_RT) {
            const p_set_rt *r = aq; memset(cf, 0, sizeof cf); dfull = sfull = 0; samples = 1;
            for (int i = 0; i < r->n && i < 8; i++) { id<MTLTexture> t = r->color[i] && !rt_dup_slot(r, i) ? tex_mtl(r->color[i]) : nil; if (t) { cf[i] = (uint32_t)rt_color_fmt(t, &r->cview[i], r->has_cview[i], 0); samples = (uint32_t)t.sampleCount; } }
            id<MTLTexture> dt = r->depth ? tex_mtl(r->depth) : nil;
            if (dt) { MTLPixelFormat f = dt.pixelFormat; samples = (uint32_t)dt.sampleCount;
                dfull = f != MTLPixelFormatStencil8 ? (uint32_t)f : 0; sfull = (f == MTLPixelFormatStencil8 || f == MTLPixelFormatDepth32Float_Stencil8) ? (uint32_t)f : 0; }
            df = dfull; sf = sfull; continue;
        }
        if (hq.op == OP_DRAW || hq.op == OP_DRAW_IDX) {
            draws++;
            __unsafe_unretained NvProg *pr = S.prog ? prog_get(S.prog) : nil; if (!pr || !pr->sh[0]) continue;
            __unsafe_unretained NvShader *vs = pr->sh[0], *fs = pr->sh[1];
            const uint32_t dv[4] = {dfull, 0, 0, dfull}, sv[4] = {sfull, 0, sfull, 0};
            for (int v = 0; v < 4; v++) {
                if (v && dv[v] == dv[0] && sv[v] == sv[0]) continue;
                if (v == 2 && !sfull) continue; if (v == 3 && (!dfull || !sfull)) continue;
                pso_key k; pso_key_fill(&k, vs, fs, cf, dv[v], sv[v], samples, 0);
                if (hm_get_id(&g_pso, &k)) continue;
                int dup = 0; for (int i = 0; i < (v ? nb : na) && !dup; i++) dup = !memcmp(&(v ? qb : qa)[i].k, &k, sizeof k);
                if (dup) continue;
                if (!v && na < QN) { qa[na].k = k; qa[na].vs = (__bridge void *)vs; qa[na].fs = (__bridge void *)fs; na++; }
                else if (v && nb < QN) { qb[nb].k = k; qb[nb].vs = (__bridge void *)vs; qb[nb].fs = (__bridge void *)fs; nb++; }
            }
            continue;
        }
        if (hq.op == OP_CLEAR_COLOR || hq.op == OP_CLEAR_DS) continue;
        state_op(hq.op, aq);
    }
    (void)df; (void)sf;
    for (int i = 0; i < na; i++) pso_pend_kick(&qa[i].k, (__bridge NvShader *)qa[i].vs, (__bridge NvShader *)qa[i].fs);
    for (int i = 0; i < nb; i++) pso_pend_kick(&qb[i].k, (__bridge NvShader *)qb[i].vs, (__bridge NvShader *)qb[i].fs);
    memcpy(&S, &Ssave, sizeof S); args_dirty_all(); g_pso_dirty = pso_dirty; g_dss_dirty = dss_dirty; R.sc = sc0; R.has_sc = hsc0;
    static int logged; if (g_pp_kicked > (uint64_t)kicked0 && logged++ < 20) MLOG("parallel precompile: %d draws left in this submit, %d pipelines handed to the background", draws, (int)g_pp_kicked - kicked0);
}

static void fz_probe_cov2(const p_set_rt *r2, const uint8_t *first, const int8_t *p2map, const uint8_t *clr, int n1, int n) {
    static typeof(S) Ssave; memcpy(&Ssave, &S, sizeof S); typeof(R) Rsave = R;
    const p_draw *fdw = g_fd_dw; const p_draw_idx *fdi = g_fd_di; int fdwhy = g_fd_why;
    int pso_dirty = g_pso_dirty, dss_dirty = g_dss_dirty;
    op_hdr fh; memcpy(&fh, first, sizeof fh);
    g_fd_dw = fh.op == OP_DRAW ? (const p_draw *)(first + 8) : NULL;
    g_fd_di = fh.op == OP_DRAW_IDX ? (const p_draw_idx *)(first + 8) : NULL;
    R.rt = *r2; R.has_rt = 1;
    fz_cursor cur = {.p = g_exec_next};
    for (;;) {
        const uint8_t *q; op_hdr hq; const void *aq;
        if (!fz_next(&cur, &q, &hq, &aq)) break;
        if (q == first) break;
        if (hq.op == OP_DRAW || hq.op == OP_DRAW_IDX || hq.op == OP_SET_RT || hq.op == OP_CLEAR_COLOR || hq.op == OP_CLEAR_DS) continue;
        state_op(hq.op, aq);
    }
    for (int j = n1; j < n && j < 8; j++) {
        int k = -1;
        for (int q = 0; q < 8; q++) if (p2map[q] == j) { k = q; break; }
        if (k < 0 || clr[k] || !r2->color[k]) continue;
        uint64_t ser; int level, slice;
        rt_sub(r2, k, &ser, &level, &slice);
        (void)ser; (void)slice;
        g_fz.cov2[j] = (uint8_t)first_draw_covers(k, tex_mtl(r2->color[k]), (NSUInteger)level);
    }
    memcpy(&S, &Ssave, sizeof S); args_dirty_all(); R = Rsave;
    g_fd_dw = fdw; g_fd_di = fdi; g_fd_why = fdwhy;
    g_pso_dirty = pso_dirty; g_dss_dirty = dss_dirty;
}

static int fz_load_covers(int i, id<MTLTexture> t, NSUInteger level) {
    if (g_fz.active && g_fz.phase == 1 && i >= g_fz.n1) return g_fz.cov2[i];
    return first_draw_covers(i, t, level);
}

// Probe wrap-up: for every attachment changed to clear to the sentinel color, read back that level / layer, compare pixel by pixel with a same-format 1x1 sentinel pixel, and count what remains (> 0 means the coverage proof is wrong, report a failure)
static void lp_finish(void) {
    id<MTLCommandBuffer> dcb = q_cb();
    NSArray *ps = g_lp; g_lp = nil;
    for (NSArray *e in ps) {
        id<MTLTexture> t = e[0]; NSUInteger lv = [e[1] unsignedIntegerValue], sl = [e[2] unsignedIntegerValue];
        NSUInteger W = MAX(t.width >> lv, 1), H = MAX(t.height >> lv, 1), bpp = (NSUInteger)(att_bytes(t, lv) / (W * H));
        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:t.pixelFormat width:1 height:1 mipmapped:NO];
        rd.usage = MTLTextureUsageRenderTarget; rd.storageMode = MTLStorageModePrivate;
        id<MTLTexture> ref = [g_dev newTextureWithDescriptor:rd];
        MTLRenderPassDescriptor *pd = [MTLRenderPassDescriptor renderPassDescriptor];
        pd.colorAttachments[0].texture = ref; pd.colorAttachments[0].loadAction = MTLLoadActionClear; pd.colorAttachments[0].storeAction = MTLStoreActionStore;
        pd.colorAttachments[0].clearColor = [e[6] intValue] == 3 ? MTLClearColorMake(NAN, NAN, NAN, NAN) : [e[6] intValue] == 2 ? MTLClearColorMake(0.777, 0.222, 0.555, 0.888) : MTLClearColorMake(0.123, 0.456, 0.789, 0.321);
        [[dcb renderCommandEncoderWithDescriptor:pd] endEncoding];
        id<MTLBuffer> bt = [g_dev newBufferWithLength:W * H * bpp options:MTLResourceStorageModeShared], br = [g_dev newBufferWithLength:bpp options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> b = [dcb blitCommandEncoder];
        [b copyFromTexture:t sourceSlice:sl sourceLevel:lv sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1) toBuffer:bt destinationOffset:0 destinationBytesPerRow:W * bpp destinationBytesPerImage:W * H * bpp];
        [b copyFromTexture:ref sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(1, 1, 1) toBuffer:br destinationOffset:0 destinationBytesPerRow:bpp destinationBytesPerImage:bpp];
    enc_b_end(b);
        unsigned long long pass = [e[3] unsignedLongLongValue], ser = [e[5] unsignedLongLongValue]; int idx = [e[4] intValue];
        [dcb addCompletedHandler:^(id<MTLCommandBuffer> c) { (void)c;
            const uint8_t *p = bt.contents, *r = br.contents; uint64_t left = 0; char at[96] = ""; size_t ao = 0;
            for (NSUInteger k = 0; k < W * H; k++) if (!memcmp(p + k * bpp, r, bpp)) { if (left++ < 4) ao += snprintf(at + ao, sizeof at - ao, " (%lu,%lu)", (unsigned long)(k % W), (unsigned long)(k / W)); }
            if (left) MLOG("[red] load-elision probe: pass %llu c%d ser=%llu lv%lu sl%lu %lux%lu sentinel pixels left %llu, first positions%s", pass, idx, ser, (unsigned long)lv, (unsigned long)sl, (unsigned long)W, (unsigned long)H, (unsigned long long)left, at);
            else MLOG("load-elision probe: pass %llu c%d ser=%llu lv%lu sl%lu %lux%lu fully covered (0 sentinel left)", pass, idx, ser, (unsigned long)lv, (unsigned long)sl, (unsigned long)W, (unsigned long)H);
        }];
    }
    [dcb commit];
}
static int rt_same(const p_set_rt *a, const p_set_rt *b) {   // Same set of targets: compare by texture serial and view (not by object pointer: the game may copy texture objects by value)
    if (a->n != b->n || !a->depth != !b->depth || (a->depth && a->depth->serial != b->depth->serial) || a->has_dview != b->has_dview) return 0;
    if (a->has_dview && memcmp(&a->dview, &b->dview, sizeof a->dview)) return 0;
    for (int k = 0; k < a->n && k < 8; k++) {
        if (!a->color[k] != !b->color[k] || (a->color[k] && a->color[k]->serial != b->color[k]->serial) || a->has_cview[k] != b->has_cview[k]) return 0;
        if (a->has_cview[k] && memcmp(&a->cview[k], &b->cview[k], sizeof a->cview[k])) return 0;
    }
    return 1;
}
// Experimental RT range candidate: only ignore positive nlevels differences not used by the actual render attachments; other fields stay word-for-word identical.
#define NVN_RT_RANGE_IMPL 1
static int rt_range_shape(const p_set_rt *a, const p_set_rt *b) {
    if (a->n != 1 || b->n != 1 || !a->color[0] || !b->color[0] || !a->has_cview[0] || !b->has_cview[0] ||
        !a->depth != !b->depth || a->has_dview != b->has_dview ||
        (a->has_dview && memcmp(&a->dview,&b->dview,sizeof a->dview))) return 0;
    const tex_t *x=a->color[0], *y=b->color[0];
    if (!x->serial || x->serial != y->serial || x->d.target != NVN_TEXTURE_TARGET_2D || y->d.target != NVN_TEXTURE_TARGET_2D ||
        x->d.samples > 1 || y->d.samples > 1 || (x->has_layout && x->mem) || (y->has_layout && y->mem) ||
        memcmp(&x->d,&y->d,sizeof x->d) || x->mem != y->mem || x->pool != y->pool || x->off != y->off) return 0;
    const view_t *v=&a->cview[0], *w=&b->cview[0]; int levels=x->d.levels;
    if (!v->set_levels || !w->set_levels || v->base_level < 0 || v->base_level >= levels ||
        v->nlevels <= 0 || v->nlevels > levels-v->base_level || w->nlevels <= 0 || w->nlevels > levels-v->base_level ||
        (v->set_layers && (v->min_layer || v->nlayers != 1)) || (v->set_format && v->format != x->d.format) ||
        (v->set_target && v->target != NVN_TEXTURE_TARGET_2D)) return 0;
    view_t cv=*w; cv.nlevels=v->nlevels;
    if (memcmp(v,&cv,sizeof cv)) return 0;
    if (a->depth) { const tex_t *d=a->depth,*e=b->depth;
        if (!d->serial || d->serial != e->serial || d->d.target != NVN_TEXTURE_TARGET_2D || e->d.target != NVN_TEXTURE_TARGET_2D ||
            d->d.samples > 1 || e->d.samples > 1 || (d->has_layout && d->mem) || (e->has_layout && e->mem) ||
            memcmp(&d->d,&e->d,sizeof d->d) || d->mem != e->mem || d->pool != e->pool || d->off != e->off) return 0;
        int dl=a->has_dview && a->dview.set_levels ? a->dview.base_level : 0;
        if (dl < 0 || dl >= d->d.levels || mip_extent(d->d.width,dl) < mip_extent(x->d.width,v->base_level) ||
            mip_extent(d->d.height,dl) < mip_extent(x->d.height,v->base_level)) return 0; }

    return v->nlevels != w->nlevels;
}
#define NVN_RT_RANGE_DEPTH_IMPL 1
static void rt_range_note_depth(void) { if (rt_range_on() && S.ds.dw) g_pass.range_depth_nonro=1; }
static int rt_range_same(const p_set_rt *a, const p_set_rt *b) {
    if (!rt_range_on() || !g_enc || g_fz.active || g_pass.range_external || g_pass.range_depth_nonro || !S.ds.dt || S.ds.dw || S.ds.st || g_enc_mode != 4 || !g_pass.hd || g_pass.hs ||
        (g_vis_on && !g_enc_has_vis) || g_pass.reg_gen != g_reg_gen || g_pass.ser_gen != g_ser_gen || g_pass.range_dirty != nvn_dirty_now() || !rt_range_shape(a,b) || !b->depth) return 0;
    id<MTLTexture> color=tex_mtl(b->color[0]), depth=tex_mtl(b->depth);
    int lv=b->cview[0].base_level;
    return mip_extent(color.width,lv) == g_pass.tw && mip_extent(color.height,lv) == g_pass.th &&
        color == g_pass.range_color && depth == g_pass.range_depth && color.textureType == MTLTextureType2D &&
        depth.textureType == MTLTextureType2D && color.sampleCount == 1 && depth.sampleCount == 1 &&
        g_pass.reg_gen == g_reg_gen && g_pass.ser_gen == g_ser_gen && g_pass.range_dirty == nvn_dirty_now();
}
static int draw_samples_rt(NvProg *pr) {   // Sampled attachments keep the original conservative ser-level guard, not split by level/layer
    uint64_t rs[9]; int nr = 0;
    for (int k = 0; k < R.rt.n && k < 8; k++) if (R.rt.color[k]) rs[nr++] = R.rt.color[k]->serial;
    if (R.rt.depth) rs[nr++] = R.rt.depth->serial;
    if (!pr) return 1;
    for (int st = 0; st < 5; st++) { __unsafe_unretained NvShader *sh = pr->sh[st]; if (!sh) continue;
        for (int i = 0; i < sh->rf.nb; i++) { const nvn_rbind *b = &sh->rf.b[i]; uint64_t h;
            if (b->kind == NVN_RB_IMG) h = b->reg < 32 && sh->stage < 6 ? S.img[sh->stage][b->reg] : 0; else if (b->kind == NVN_RB_TEX || b->kind == NVN_RB_TBUF) h = b->reg < 128 && sh->stage < 6 ? S.tex[sh->stage][b->reg] : 0; else continue;
            int tid = (int)(h & 0xfffff); if (!tid) continue;
            pthread_mutex_lock(&g_rmu); uint64_t ser = tid < g_ntreg && g_treg[tid].ok ? g_treg[tid].t.serial : 0; pthread_mutex_unlock(&g_rmu);
            for (int j = 0; j < nr; j++) if (ser && ser == rs[j]) return 1; } }
    return 0;
}
// DM_NVN_COUNTS=1 (diagnostics, measured for plan items 42-44 before any change): per frame, draws that sample the levels and layers their own pass
// draws into, those of them after other draws of the same Metal pass (they read what the pass started with: the earlier draws' results are still in
// tile memory), and those with an NVN barrier after such a draw (on the console the barrier makes those results visible; the replay keeps the pass);
// timestamp reports and the submissions with two or more of them, ClearTexture calls, and render passes that end without a draw. Printed with the
// power summary (hle_nvn.c); cntpct reads are hle.c's
// [lo, hi) of levels and layers a view covers: a sampled view, or the one level an attachment renders (all layers when the view sets none)
static void view_span(const view_t *v, int has_v, const tex_t *t, int attach, int *l0, int *l1, int *y0, int *y1) {
    int levels = t->d.levels ? t->d.levels : 1;
    *l0 = has_v && v->set_levels ? v->base_level : 0;
    *l1 = attach ? *l0 + 1 : has_v && v->set_levels && v->nlevels ? *l0 + v->nlevels : levels;
    if (has_v && v->set_layers) { *y0 = v->min_layer; *y1 = v->min_layer + (v->nlayers ? v->nlayers : 1); } else { *y0 = 0; *y1 = 1 << 16; }
}
static void count_self_sample(NvProg *pr) {
    if (!pr || (!R.rt.n && !R.rt.depth)) return;
    int hit = 0, ov = 0, dep = 0; g_cnt_why[0] = 0;
    for (int st = 0; st < 5; st++) { __unsafe_unretained NvShader *sh = pr->sh[st]; if (!sh) continue;
        for (int i = 0; i < sh->rf.nb; i++) { const nvn_rbind *b = &sh->rf.b[i]; uint64_t h;
            if (b->kind == NVN_RB_IMG) h = b->reg < 32 && sh->stage < 6 ? S.img[sh->stage][b->reg] : 0; else if (b->kind == NVN_RB_TEX || b->kind == NVN_RB_TBUF) h = b->reg < 128 && sh->stage < 6 ? S.tex[sh->stage][b->reg] : 0; else continue;
            int tid = (int)(h & 0xfffff); if (!tid) continue;
            treg_t r; int ok = 0; pthread_mutex_lock(&g_rmu); if (tid < g_ntreg && g_treg[tid].ok) { r = g_treg[tid]; ok = 1; } pthread_mutex_unlock(&g_rmu);
            if (!ok) continue;
            int l0, l1, y0, y1; view_span(&r.v, r.has_v, &r.t, 0, &l0, &l1, &y0, &y1);
            for (int k = 0; k <= 8; k++) {
                const tex_t *a = k < 8 ? (k < R.rt.n ? R.rt.color[k] : NULL) : R.rt.depth; if (!a || a->serial != r.t.serial) continue;
                hit = 1; if (k == 8) dep = 1;
                int m0, m1, z0, z1; view_span(k < 8 ? &R.rt.cview[k] : &R.rt.dview, k < 8 ? R.rt.has_cview[k] : R.rt.has_dview, a, 1, &m0, &m1, &z0, &z1);
                if (l0 < m1 && m0 < l1 && y0 < z1 && z0 < y1) { ov = 1;
                    if (!g_cnt_why[0]) snprintf(g_cnt_why, sizeof g_cnt_why, "texture %ux%u, %d levels, %d layers; samples levels %d-%d layers %d-%d, draws level %d layers %d-%d%s",
                        r.t.d.width, r.t.d.height, r.t.d.levels, r.t.d.depth, l0, l1 - 1, y0, y1 > 65535 ? -1 : y1 - 1, m0, z0, z1 > 65535 ? -1 : z1 - 1, k == 8 ? " (depth)" : ""); }
            } } }
    (void)hit; (void)dep;
    if (ov) { g_cnt_self++; if (g_stat_draw > g_cnt_pass_d0) { g_cnt_self_ov++; if (g_cnt_bar_at > g_cnt_pass_d0) g_cnt_self_dep++; }
        static char seen[16][9]; static int nseen;   // the first 16 fragment shaders seen doing it, with the pass
        if (nseen < 16 && pr->sh[1]) { int k = 0; while (k < nseen && memcmp(seen[k], pr->sh[1]->key, 8)) k++;
            if (k == nseen) { memcpy(seen[nseen++], pr->sh[1]->key, 8);
                MLOG("counts: fragment shader %.8s samples what its pass draws (pass %llu, %u x %u, %d colour targets, draw %llu of the pass, barrier since %d): %s", pr->sh[1]->key,
                     (unsigned long long)g_stat_pass, (unsigned)g_pass.tw, (unsigned)g_pass.th, R.rt.n, (unsigned long long)(g_stat_draw - g_cnt_pass_d0), g_cnt_bar_at > g_cnt_pass_d0, g_cnt_why); } } }
}
// Before a draw (see fbx_sub): the attachments it samples where it draws, copied unless a copy is still current; the copies stand in for them
static void fbx_prepare(NvProg *pr) {
    g_fbx_npend = 0;
    if (g_fbx_nact) { g_fbx_nact = 0; args_dirty_all(); }
    if (g_fbx_on < 0) { const char *e = getenv("DM_NVN_FBX"); g_fbx_on = !e ? 1 : !strcmp(e, "0") ? 0 : !strcmp(e, "all") ? 2 : 1; }
    if (!g_fbx_on || !pr || (!R.rt.n && !R.rt.depth)) return;
    if (g_fbx_on == 1 && !(g_enc && g_stat_draw > g_cnt_pass_d0 && g_fbx_bar_at > g_cnt_pass_d0)) return;   // no barrier after draws of this pass: read as the console does
    uint64_t rs[9]; int nr = 0;
    for (int k = 0; k < 9; k++) { const tex_t *a = k < 8 ? (k < R.rt.n ? R.rt.color[k] : NULL) : R.rt.depth; rs[k] = a ? a->serial : 0; nr += a != NULL; }
    if (!nr) return;
    unsigned need = 0;
    for (int st = 0; st < 5; st++) { __unsafe_unretained NvShader *sh = pr->sh[st]; if (!sh) continue;
        for (int i = 0; i < sh->rf.nb; i++) { const nvn_rbind *b = &sh->rf.b[i];
            if (b->kind != NVN_RB_TEX || b->reg >= 128 || sh->stage >= 6) continue;
            int tid = (int)(S.tex[sh->stage][b->reg] & 0xfffff); if (!tid) continue;
            uint64_t ser = atomic_load_explicit(&g_tser[tid], memory_order_relaxed); if (!ser) continue;   // lock-free first look
            int any = 0; for (int k = 0; k < 9; k++) any |= rs[k] == ser; if (!any) continue;
            treg_t r; int ok = 0; pthread_mutex_lock(&g_rmu); if (tid < g_ntreg && g_treg[tid].ok) { r = g_treg[tid]; ok = 1; } pthread_mutex_unlock(&g_rmu);
            if (!ok) continue;
            int l0, l1, y0, y1; view_span(&r.v, r.has_v, &r.t, 0, &l0, &l1, &y0, &y1);
            for (int k = 0; k < 9; k++) {
                const tex_t *a = k < 8 ? (k < R.rt.n ? R.rt.color[k] : NULL) : R.rt.depth; if (!a || a->serial != r.t.serial) continue;
                int m0, m1, z0, z1; view_span(k < 8 ? &R.rt.cview[k] : &R.rt.dview, k < 8 ? R.rt.has_cview[k] : R.rt.has_dview, a, 1, &m0, &m1, &z0, &z1);
                if (l0 < m1 && m0 < l1 && y0 < z1 && z0 < y1) need |= 1u << k;
            } } }
    if (!need) return;
    if (g_fz.active || g_lay.active || g_rt_range_active) { g_fbx_refused++; RED_ONCE(97, "a draw samples what its pass draws inside a merged, layered or range pass: not copied (first case pass %llu)", g_stat_pass); return; }
    g_fbx_draws++;
    id<MTLTexture> src[9]; int ns = 0, stale = 0;
    for (int k = 0; k < 9; k++) if (need >> k & 1) { id<MTLTexture> t = tex_mtl(k < 8 ? R.rt.color[k] : R.rt.depth); if (!t) continue;
        int dup = 0; for (int j = 0; j < ns; j++) dup |= src[j] == t; if (dup) continue;
        src[ns++] = t; }
    int pick[9];
    for (int j = 0; j < ns; j++) {   // a current copy of it, else a copy texture of its shape this draw does not use yet
        pick[j] = -1;
        for (int i = 0; i < g_nfbx; i++) if (g_fbx[i].src == src[j] && g_fbx[i].draw == g_stat_draw && g_fbx[i].sub == g_fence + 1) { pick[j] = i; break; }
        if (pick[j] >= 0) continue;
        stale = 1; id<MTLTexture> t = src[j];
        for (int i = 0; i < g_nfbx && pick[j] < 0; i++) { id<MTLTexture> c = g_fbx[i].copy; int used = 0; for (int q = 0; q < j; q++) used |= pick[q] == i;
            if (!used && c.textureType == t.textureType && c.pixelFormat == t.pixelFormat && c.width == t.width && c.height == t.height && c.depth == t.depth &&
                c.mipmapLevelCount == t.mipmapLevelCount && c.arrayLength == t.arrayLength && c.sampleCount == t.sampleCount) pick[j] = i; }
        if (pick[j] < 0) {
            int i = g_nfbx < 16 ? g_nfbx++ : 15;
            if (g_fbx[i].copy) { defer_obj_release(g_fbx[i].copy); for (int q = 0; q < g_fbx[i].nv; q++) defer_obj_unref(g_fbx[i].view[q]); }
            MTLTextureDescriptor *d = [MTLTextureDescriptor new];
            d.textureType = t.textureType; d.pixelFormat = t.pixelFormat; d.width = t.width; d.height = t.height; d.depth = t.depth;
            d.mipmapLevelCount = t.mipmapLevelCount; d.arrayLength = t.arrayLength; d.sampleCount = t.sampleCount;
            d.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView; d.storageMode = MTLStorageModePrivate;
            id<MTLTexture> c = [g_dev newTextureWithDescriptor:d];
            if (!c) { RED_ONCE(96, "attachment copy: cannot make a %lux%lu copy texture; the draw samples the attachment", (unsigned long)t.width, (unsigned long)t.height); g_fbx[i] = (fbx_ent){0}; if (i == g_nfbx - 1) g_nfbx--; return; }
            res_add(c); g_fbx[i] = (fbx_ent){.copy = c}; pick[j] = i;
        }
    }
    if (stale) {
        if (!g_enc && (R.clear_d || R.clear_s || memchr(R.clear_c, 1, sizeof R.clear_c))) rp_begin();   // clears still pending: the copy must hold them
        rp_end();
        for (int j = 0; j < ns; j++) { fbx_ent *e = &g_fbx[pick[j]];
            if (e->src == src[j] && e->draw == g_stat_draw && e->sub == g_fence + 1) continue;
            [(id)blit() copyFromTexture:src[j] toTexture:e->copy];
            if (e->src != src[j]) { for (int q = 0; q < e->nv; q++) defer_obj_unref(e->view[q]); memset(e->vsrc, 0, sizeof e->vsrc); memset(e->view, 0, sizeof e->view); e->nv = 0; }
            e->src = src[j]; e->draw = g_stat_draw; e->sub = g_fence + 1; g_fbx_copies++; }
    }
    for (int j = 0; j < ns; j++) g_fbx_pend[g_fbx_npend++] = pick[j];
}
// The draw's pass is open: its copies stand in from here (passes run in between, as the TBDR path's hoisted clears, ended without them)
static void fbx_activate(void) {
    if (!g_fbx_npend) return;
    memcpy(g_fbx_act, g_fbx_pend, sizeof g_fbx_act); g_fbx_nact = g_fbx_npend; g_fbx_npend = 0; args_dirty_all();
}
// The whole render pass's need for depth / stencil (bits: 1 depth 2 stencil; 3 = both needed or cannot be proven). Starting from the draw that opens the render pass, scan in real replay order to the end of the render pass:
// the attached clears and this draw's state are counted first; later draws accumulate by their depth-stencil state; anything unprovable such as a mid-pass clear or nesting too deep is treated as both needed
static int pass_ds_need(void) {
    int need = (R.clear_d || S.ds.dt || S.ds.dw ? 1 : 0) | (R.clear_s || S.ds.st ? 2 : 0);
    if (!R.rt.depth || need == 3 || !g_exec_next || g_ret_n > 16) {
        PD("S %llu no lookahead depth=%d clear_d=%d clear_s=%d dt=%d dw=%d st=%d next=%d ret=%d", g_stat_pass + 1, R.rt.depth != NULL, R.clear_d, R.clear_s, (int)S.ds.dt, (int)S.ds.dw, (int)S.ds.st, g_exec_next != NULL, g_ret_n);
        return 3;
    }
    ds_st ds = S.ds; g_ds_why = -1; g_ds_scanned = 0; g_ds_need = need;
    int r = ds_scan(g_exec_next, &ds, 0);
    for (int k = g_ret_n - 1; r == DS_RET && k >= 0; k--) r = ds_scan(g_ret[k], &ds, 0);
    for (int k = 0; r == DS_RET && k < g_nrest; k++) r = ds_scan((const uint8_t *)g_rest[k], &ds, 0);
    int out = r == DS_USED ? 3 : g_ds_need;
    PD("S %llu lookahead result=%d need=%d (1 depth 2 stencil) why=%d scanned %d ops return stack %d remaining handles %d", g_stat_pass + 1, r, out, g_ds_why, g_ds_scanned, g_ret_n, g_nrest);
    return out;
}
// Pure-clear render pass hoisting: when a render pass is opened, scan forward, and if the shape is "several draws of this render pass -> several groups (SetRenderTargets + only clears) -> back to the same targets as this render pass",
// then hoist those groups of clears to execute before this render pass and skip them at their original positions, and on returning to the same targets the same-target continuation picks up -- this render pass's attachments are no longer stored whole and loaded again for the clears sandwiched in between
// (character select page: grunge and particles both draw 28 / 27 level 0 + depth, with only levels 1 and 2 cleared in between).
// Equivalence conditions (hoist only if all hold, otherwise leave as-is): the scan range has only draws, state and these clears, no copies / dispatches / texture clears / sub-lists; the cleared subresources (texture + level + layer)
// are disjoint from this render pass's attachments; the cleared textures are neither on any current texture / image slot nor bound within the scan range (conservative: regardless of whether the program samples them); the scissor at the time of the clear covers the whole block (same requirement as executing at the original position)
static uint64_t h_ser(uint64_t h) { int tid = (int)(h & 0xfffff); return tid ? atomic_load_explicit(&g_tser[tid], memory_order_relaxed) : 0; }
// ---------- Store lookahead index: at the start of a submit do one linear scan in replay order and record events per texture; when a render pass ends, binary-search each attachment for "the first valid event afterwards" to decide ----------
// Replaces the original "scan the whole remainder forward at every render pass end" (pass count x command count, 49 render passes per frame in camp). Cross-checked per attachment against the original scan: after 0 mismatches over the 17 pages of the screenshot gate + a camp run with about 340,000 attachment decisions (about 46,000 redundant), the original scan was removed.
// Events (seq = replay sequence number): READ a draw / dispatch reads this texture per program reflection; ATT it is a current attachment at a draw; CLEAR cleared as a whole block while an attachment; COPY / CLRTEX either end of a copy / the cleared texture.
// Decision (the first valid event decides): READ / COPY / CLRTEX -> needed; ATT whose SetRenderTargets is after the render pass end -> needed (load); CLEAR with the same -> redundant; no event -> needed.
// On any uncertainty (replay sequence number does not match the index, nesting too deep) the index is invalidated and all remaining render passes of this submit store (storing is always correct, it just saves less bandwidth).
typedef struct { uint32_t seq, rtseq; uint64_t ser; const uint8_t *op; uint16_t lv, sl; uint8_t kind, plane, anyls, why; } sdx_ev;   // plane 0 color 8 depth-stencil (ATT) 1 depth 2 stencil (CLEAR)
enum { SDX_READ = 1, SDX_NEED, SDX_ATT, SDX_CLEAR };
#define SDX_NONE 0xffffffffu
static sdx_ev *g_sdx, *g_sdx_tmp; static uint32_t g_sdx_n, g_sdx_cap; static int g_sdx_ok;   // Index valid
// Candidate textures (those that have been attachments) -> buckets: open addressing; a texture that has not yet been an attachment when an event occurs is irrelevant to any render pass that ended before then, so it is not recorded
#define SDX_HB 2048
static uint64_t g_sdx_hk[SDX_HB]; static uint16_t g_sdx_hb[SDX_HB]; static uint32_t g_sdx_nb, g_sdx_bcnt[SDX_HB + 1], g_sdx_bst[SDX_HB + 1];
static int sdx_bucket(uint64_t ser, int add) {   // Returns the bucket number; returns -1 if not in the set (and not adding); invalidates the index when full
    if (!ser) return -1;
    for (uint32_t i = (uint32_t)(ser * 0x9E3779B97F4A7C15ull >> 53), n = 0; n < SDX_HB; i = (i + 1) & (SDX_HB - 1), n++) {
        if (g_sdx_hk[i] == ser) return g_sdx_hb[i];
        if (!g_sdx_hk[i]) { if (!add) return -1; if (g_sdx_nb >= SDX_HB / 2) { g_sdx_ok = 0; return -1; } g_sdx_hk[i] = ser; g_sdx_hb[i] = (uint16_t)g_sdx_nb; return (int)g_sdx_nb++; }
    }
    return -1;
}
static const uint8_t **g_sdx_op; static uint32_t g_sdx_nop, g_sdx_opcap;
static uint32_t g_exec_seq;   // Sequence number of the current operation during replay
static uint64_t g_pp_slot[6][160]; static const prog_t *g_pp_prog; static const p_set_rt *g_pp_rt; static uint32_t g_pp_rtseq; static int g_pp_ren_maybe_off;   // render enable not known to be on (see sdx_walk)
static p_scissor g_pp_sc; static int g_pp_has_sc;   // scissor at that point of the walk: a clear under a partial scissor leaves the rest of the target (see clear_quad)
static uint32_t *g_rtx_seq, *g_drx_seq; static uint32_t g_rtx_n, g_rtx_cap, g_drx_n, g_drx_cap;   // This submit's SET_RT / draw sequence number tables (used by the pre-screen of the readable tile merge)
static void seq_push(uint32_t **v, uint32_t *n, uint32_t *cap, uint32_t x) { if (*n == *cap) { *cap = *cap ? *cap * 2 : 1024; *v = realloc(*v, *cap * sizeof **v); } (*v)[(*n)++] = x; }
static void sdx_ev_add(sdx_ev e) { if (sdx_bucket(e.ser, 0) < 0) return; if (g_sdx_n == g_sdx_cap) { g_sdx_cap = g_sdx_cap ? g_sdx_cap * 2 : 4096; g_sdx = realloc(g_sdx, g_sdx_cap * sizeof *g_sdx); g_sdx_tmp = realloc(g_sdx_tmp, g_sdx_cap * sizeof *g_sdx); } g_sdx[g_sdx_n++] = e; }
static void sdx_lvsl(const view_t *v, int hv, uint16_t *lv, uint16_t *sl) { *lv = (uint16_t)(hv && v->set_levels ? v->base_level : 0); *sl = (uint16_t)(hv && v->set_layers ? v->min_layer : 0); }
static void sdx_walk(const uint8_t *p, int depth) {
    if (depth > 64) { g_sdx_ok = 0; return; }
    for (uint32_t guard = 0; guard < 4000000 && p && g_sdx_ok; guard++) {
        op_hdr h; memcpy(&h, p, sizeof h); const void *a = p + 8;
        if (g_sdx_nop == g_sdx_opcap) { g_sdx_opcap = g_sdx_opcap ? g_sdx_opcap * 2 : 16384; g_sdx_op = realloc(g_sdx_op, g_sdx_opcap * sizeof *g_sdx_op); }
        uint32_t seq = g_sdx_nop; g_sdx_op[g_sdx_nop++] = p;
        switch (h.op) {
            case OP_END: return;
            case OP_JUMP: { const uint8_t *t; memcpy(&t, a, 8); p = t; continue; }
            case OP_CALL: { uint64_t t; memcpy(&t, a, 8); sdx_walk((const uint8_t *)t, depth + 1); break; }
            case OP_SET_RT: { const p_set_rt *r = a; g_pp_rt = r; g_pp_rtseq = seq; seq_push(&g_rtx_seq, &g_rtx_n, &g_rtx_cap, seq);
                for (int k = 0; k < r->n && k < 8; k++) if (r->color[k]) sdx_bucket(r->color[k]->serial, 1);
                if (r->depth) sdx_bucket(r->depth->serial, 1);
                break; }
            case OP_RENDER_ENABLE: g_pp_ren_maybe_off = ((const p_render_enable *)a)->mode != 1; break;   // a clear while rendering may be off is not counted as a clear: storing is always correct
            case OP_SCISSOR: g_pp_sc = *(const p_scissor *)a; g_pp_has_sc = 1; break;
            case OP_CLEAR_COLOR: { const p_clear_color *c = a; const p_set_rt *r = g_pp_rt;
                if (!r || g_pp_ren_maybe_off || (c->mask & 0xf) != 0xf || c->index < 0 || c->index >= r->n || c->index >= 8 || !r->color[c->index]) break;
                if (!scissor_full_of(&g_pp_sc, g_pp_has_sc, r->color[c->index], &r->cview[c->index], r->has_cview[c->index])) break;
                uint16_t lv, sl; sdx_lvsl(&r->cview[c->index], r->has_cview[c->index], &lv, &sl); int last = -1;   // When the same subresource is attached at several indices, the last one counts
                for (int k = 0; k < r->n && k < 8; k++) { uint16_t l2, s2; if (!r->color[k] || r->color[k]->serial != r->color[c->index]->serial) continue; sdx_lvsl(&r->cview[k], r->has_cview[k], &l2, &s2); if (l2 == lv && s2 == sl) last = k; }
                if (last == c->index) sdx_ev_add((sdx_ev){seq, g_pp_rtseq, r->color[c->index]->serial, p, lv, sl, SDX_CLEAR, 0, 0, 0});
                break; }
            case OP_CLEAR_DS: { const p_clear_ds *c = a; const p_set_rt *r = g_pp_rt; if (!r || !r->depth || g_pp_ren_maybe_off || !scissor_full_of(&g_pp_sc, g_pp_has_sc, r->depth, &r->dview, r->has_dview)) break;
                uint16_t lv, sl; sdx_lvsl(&r->dview, r->has_dview, &lv, &sl);
                if (c->depth_mask) sdx_ev_add((sdx_ev){seq, g_pp_rtseq, r->depth->serial, p, lv, sl, SDX_CLEAR, 1, !r->has_dview, 0});
                if ((c->stencil_mask & 0xff) == 0xff) sdx_ev_add((sdx_ev){seq, g_pp_rtseq, r->depth->serial, p, lv, sl, SDX_CLEAR, 2, !r->has_dview, 0});
                break; }
            case OP_BIND_TEX: case OP_BIND_IMG: { const p_bind_handles *b = a; bh_fresh(b); int base = h.op == OP_BIND_IMG ? 128 : 0, lim = h.op == OP_BIND_IMG ? 32 : 128;
                if (b->stage < 6 && b->first >= 0 && b->first + b->n <= lim) for (int k = 0; k < b->n; k++) g_pp_slot[b->stage][base + b->first + k] = h_ser(b->h[k]);
                break; }
            case OP_BIND_PROGRAM: g_pp_prog = prog_bind(g_pp_prog, ((const p_bind_program *)a)->prog, ((const p_bind_program *)a)->stages); break;
            case OP_DRAW: case OP_DRAW_IDX: case OP_DISPATCH: {
                if (h.op != OP_DISPATCH) seq_push(&g_drx_seq, &g_drx_n, &g_drx_cap, seq);
                __unsafe_unretained NvProg *pr = g_pp_prog ? prog_get(g_pp_prog) : nil;
                if (!pr) { for (int st = 0; st < 6; st++) for (int k = 0; k < 160; k++) if (g_pp_slot[st][k]) sdx_ev_add((sdx_ev){seq, 0, g_pp_slot[st][k], p, 0, 0, SDX_READ, 0, 0, 1}); }
                else for (int st = 0; st < 6; st++) { __unsafe_unretained NvShader *sh = pr->sh[st]; if (!sh || (h.op == OP_DISPATCH) != (st == 5)) continue;
                    for (int i = 0; i < sh->rf.nb; i++) { const nvn_rbind *b = &sh->rf.b[i]; int k = b->kind == NVN_RB_IMG ? 128 + b->reg : (b->kind == NVN_RB_TEX || b->kind == NVN_RB_TBUF) ? b->reg : -1;
                        if (k < 0 || k >= 160 || sh->stage < 0 || sh->stage >= 6) continue; uint64_t ser = g_pp_slot[sh->stage][k];
                        if (ser) sdx_ev_add((sdx_ev){seq, 0, ser, p, 0, 0, SDX_READ, 0, 0, 1}); } }
                const p_set_rt *r = g_pp_rt;
                if (h.op != OP_DISPATCH && r) {
                    for (int k = 0; k < r->n && k < 8; k++) if (r->color[k]) { uint16_t lv, sl; sdx_lvsl(&r->cview[k], r->has_cview[k], &lv, &sl); sdx_ev_add((sdx_ev){seq, g_pp_rtseq, r->color[k]->serial, p, lv, sl, SDX_ATT, 0, 0, 2}); }
                    if (r->depth) { uint16_t lv, sl; sdx_lvsl(&r->dview, r->has_dview, &lv, &sl); sdx_ev_add((sdx_ev){seq, g_pp_rtseq, r->depth->serial, p, lv, sl, SDX_ATT, 8, !r->has_dview, 2}); }
                }
                break; }
            case OP_COPY_T2T: { const p_copy_t2t *c = a; if (c->src) sdx_ev_add((sdx_ev){seq, 0, c->src->serial, p, 0, 0, SDX_NEED, 0, 0, 3}); if (c->dst) sdx_ev_add((sdx_ev){seq, 0, c->dst->serial, p, 0, 0, SDX_NEED, 0, 0, 3}); break; }
            case OP_COPY_T2B: case OP_COPY_B2T: { const p_copy_b2t *c = a; if (c->tex) sdx_ev_add((sdx_ev){seq, 0, c->tex->serial, p, 0, 0, SDX_NEED, 0, 0, 3}); break; }
            case OP_CLEAR_TEX: { const p_clear_tex *c = a; if (c->tex) sdx_ev_add((sdx_ev){seq, 0, c->tex->serial, p, 0, 0, SDX_NEED, 0, 0, 4}); break; }
            default: break;
        }
        p += h.size;
    }
}
void mtl_sub_index(const uint64_t *h, int n) {   // Start of submit (hle_nvn.c QueueSubmitCommands): build this submit's store lookahead index
    g_xv_ntouch = 0; g_sdx_n = g_sdx_nop = 0; g_rtx_n = g_drx_n = 0; g_exec_seq = 0; g_sdx_ok = tbdr_on();
    if (!g_sdx_ok) { g_xv_n = 0; g_xv_block = 1; return; }   // Index unavailable: clear the ledger and add nothing in this submit (the next touch cannot be verified)
    g_xv_block = 0;
    memset(g_sdx_hk, 0, sizeof g_sdx_hk); g_sdx_nb = 0;
    for (int i = 0; i < g_xv_n; i++) sdx_bucket(g_xv[i].ser, 1);   // Textures in the ledger enter the candidate set: otherwise, when one is only sampled and not used as an attachment in this submit, its read events are not indexed and the fallback cannot see them
    if (R.has_rt) { for (int k = 0; k < R.rt.n && k < 8; k++) if (R.rt.color[k]) sdx_bucket(R.rt.color[k]->serial, 1); if (R.rt.depth) sdx_bucket(R.rt.depth->serial, 1); }   // The targets at the start of the submit (the first draw may reopen the render pass without going through SetRenderTargets)
    g_pp_prog = S.prog; g_pp_rt = NULL; g_pp_rtseq = SDX_NONE; g_pp_ren_maybe_off = g_render_off;   // render enable is queue state carried from the last submission
    g_pp_sc = R.sc; g_pp_has_sc = R.has_sc;
    for (int st = 0; st < 6; st++) { for (int k = 0; k < 128; k++) g_pp_slot[st][k] = S.tex[st][k] ? h_ser(S.tex[st][k]) : 0;
                                     for (int k = 0; k < 32; k++) g_pp_slot[st][128 + k] = S.img[st][k] ? h_ser(S.img[st][k]) : 0; }
    for (int i = 0; i < n && g_sdx_ok; i++) sdx_walk((const uint8_t *)h[i], 0);
    if (!g_sdx_ok) return;
    // Counting sort into buckets: events are appended in sequence-number order, and within the same sequence number READ precedes ATT (the same draw is judged for reads first, then attachments), so after a stable scatter each bucket is ordered
    memset(g_sdx_bcnt, 0, (g_sdx_nb + 1) * sizeof *g_sdx_bcnt);
    for (uint32_t i = 0; i < g_sdx_n; i++) g_sdx_bcnt[sdx_bucket(g_sdx[i].ser, 0)]++;
    for (uint32_t b = 0, acc = 0; b <= g_sdx_nb; b++) { g_sdx_bst[b] = acc; acc += b < g_sdx_nb ? g_sdx_bcnt[b] : 0; }
    for (uint32_t b = 0; b < g_sdx_nb; b++) g_sdx_bcnt[b] = g_sdx_bst[b];
    for (uint32_t i = 0; i < g_sdx_n; i++) g_sdx_tmp[g_sdx_bcnt[sdx_bucket(g_sdx[i].ser, 0)]++] = g_sdx[i];
    sdx_ev *t = g_sdx; g_sdx = g_sdx_tmp; g_sdx_tmp = t;
    xv_forward();
}
static void sdx_seq(const uint8_t *p) {   // Every operation in mtl_exec: check the sequence number against the index (on mismatch invalidate, and store everything for the rest)
    if (!g_sdx_ok) return;
    if (g_exec_seq >= g_sdx_nop || g_sdx_op[g_exec_seq] != p) { RED_ONCE(40, "store lookahead index does not match the replay order (seq %u / %u), all remaining passes of this submit store", g_exec_seq, g_sdx_nop); g_sdx_ok = 0; return; }
    g_exec_seq++;
}
static int sdx_decide(uint8_t st[9]) {   // st[i]: 2 redundant; otherwise why << 2 (the reason it is needed, same as sd_need). Returns 0 = index unavailable
    if (!g_sdx_ok || !g_exec_cur || !g_exec_seq || g_sdx_op[g_exec_seq - 1] != g_exec_cur) return 0;
    uint32_t P = g_exec_seq - 1;
    for (int i = 0; i < g_nsd; i++) { const sd_att *t = &g_sd[i]; st[i] = 5 << 2;
        int b = sdx_bucket(t->ser, 0); if (b < 0) continue;   // Not in the candidate set: no related event at all in this submit -> undecided after scanning to the end, needed
        uint32_t lo = g_sdx_bst[b], end = g_sdx_bst[b + 1], hi = end;   // First seq >= P in the bucket
        while (lo < hi) { uint32_t m = (lo + hi) / 2; if (g_sdx[m].seq < P) lo = m + 1; else hi = m; }
        for (uint32_t j = lo; j < end; j++) { const sdx_ev *e = &g_sdx[j];
            if (g_hoist_n && hoist_skipped(e->op)) continue;
            if (e->kind == SDX_READ || e->kind == SDX_NEED) { st[i] = (uint8_t)(e->why << 2); break; }
            if (e->rtseq == SDX_NONE || e->rtseq < P || (g_hoist_n && hoist_skipped(g_sdx_op[e->rtseq]))) continue;   // This target was set before the render pass ended: not re-set as an attachment after the render pass ended, so it does not count
            int hit = t->depth ? (e->kind == SDX_ATT ? e->plane == 8 : e->plane == t->depth) && (e->anyls || (e->lv == t->lv && e->sl == t->sl))
                               : e->plane == 0 && e->lv == t->lv && e->sl == t->sl;
            if (!hit) continue;
            st[i] = e->kind == SDX_CLEAR ? 2 : (uint8_t)(2 << 2); break; }
    }
    return 1;
}
static void xv_forward(void) {
    if (!g_xv_n) return;
    if (!g_sdx_ok) { g_xv_n = 0; g_xv_block = 1; return; }
    for (int i = 0; i < g_xv_n;) {
        xv_ent *e = &g_xv[i]; int b = sdx_bucket(e->ser, 0), action = 0;
        if (b >= 0) for (uint32_t j = g_sdx_bst[b]; j < g_sdx_bst[b + 1]; j++) { sdx_ev *v = &g_sdx[j];
            if (v->kind == SDX_READ || v->kind == SDX_NEED) { xv_ent copy = *e; xv_violation(&copy, "submit lookahead read/need"); action = 2; break; }
            if (v->lv != e->lv || v->sl != e->sl) continue;
            if (v->kind == SDX_CLEAR) { xv_good(e); action = 1; break; }
            if (v->kind == SDX_ATT) break;
        }
        if (!action) i++;
    }
}
static void rt_sub(const p_set_rt *r, int k, uint64_t *ser, int *lv, int *sl) {   // Subresource of attachment k (0–7 color, 8 depth)
    const tex_t *t = k == 8 ? r->depth : r->color[k]; const view_t *v = k == 8 ? &r->dview : &r->cview[k]; int hv = k == 8 ? r->has_dview : r->has_cview[k];
    *ser = t ? t->serial : 0; *lv = hv && v->set_levels ? v->base_level : 0; *sl = hv && v->set_layers ? v->min_layer : 0;
}
static void hoist_try(void) {
    if (g_hoist_n || !g_exec_next) return;
    typedef struct { const uint8_t *rt_op; const p_set_rt *rt; uint8_t clear_c[8]; MTLClearColor cc[8]; uint8_t clear_d, clear_s; double cd; uint32_t cs;
                     p_scissor sc; int has_sc; const uint8_t *ops[8]; int nops; } grp;
    grp G[4]; int ng = 0, in_grp = 0; p_scissor sc = R.sc; int has_sc = R.has_sc;
    // The binding set needed for "the cleared texture is not on any slot": the table is looked up only when a hoistable clear group is really found and we are back to this render pass's targets (the vast majority of render passes never get that far).
    // Handles bound within the scan range are noted first and converted to texture serials together with the current slots at lookup time; the scan only reads commands and the current slots S do not change meanwhile, so the result is the same as checking at the start
    uint64_t bh[512]; int nbh = 0;
    const uint8_t *p = g_exec_next;
    for (int guard = 0; guard < 200000; guard++) {
        op_hdr h; memcpy(&h, p, sizeof h); const void *a = p + 8;
        switch (h.op) {
            case OP_END: case OP_CALL: case OP_COPY_T2T: case OP_COPY_B2T: case OP_COPY_T2B: case OP_CLEAR_TEX: case OP_DISPATCH: case OP_RENDER_ENABLE: return;   // clears are not moved across a render enable change
            case OP_JUMP: { const uint8_t *t; memcpy(&t, a, 8); p = t; continue; }
            case OP_DRAW: case OP_DRAW_IDX: if (in_grp) return; break;
            case OP_SCISSOR: sc = *(const p_scissor *)a; has_sc = 1; break;
            case OP_BIND_TEX: case OP_BIND_IMG: { const p_bind_handles *b = a; bh_fresh(b); for (int k = 0; k < b->n && k < 32 && nbh < 512; k++) if (b->h[k]) bh[nbh++] = b->h[k]; break; }
            case OP_CLEAR_COLOR: case OP_CLEAR_DS: {
                if (!in_grp || G[ng - 1].nops >= 8) return;
                grp *g = &G[ng - 1];
                if (h.op == OP_CLEAR_COLOR) { const p_clear_color *c = a;
                    if (c->index < 0 || c->index >= g->rt->n || !g->rt->color[c->index] || c->mask != 0xf) return;
                    const tex_t *t = g->rt->color[c->index];
                    if (has_sc && !(sc.x <= 0 && sc.y <= 0 && sc.x + sc.w >= (int)t->d.width && sc.y + sc.h >= (int)t->d.height)) return;
                    g->clear_c[c->index] = 1; g->cc[c->index] = MTLClearColorMake(c->rgba[0], c->rgba[1], c->rgba[2], c->rgba[3]); }
                else { const p_clear_ds *c = a; if (!g->rt->depth) return;
                    if (!scissor_full_of(&sc, has_sc, g->rt->depth, &g->rt->dview, g->rt->has_dview) || ((c->stencil_mask & 255) && (c->stencil_mask & 255) != 255)) return;   // drawn as a triangle (clear_ds_quad), not a load action
                    if (c->depth_mask) { g->clear_d = 1; g->cd = c->depth; } if (c->stencil_mask) { g->clear_s = 1; g->cs = (uint32_t)c->stencil; } }
                g->sc = sc; g->has_sc = has_sc; g->ops[g->nops++] = p; break; }
            case OP_SET_RT: { const p_set_rt *r = a;
                if (rt_same(&R.rt, r)) {   // Back to this render pass's targets: execute if hoisting holds
                    if (!ng) return;
                    uint64_t bound[512]; int nb = 0;   // The order of the original "check at the start": the current slots (stage x textures 128 + images 32), followed by those bound within the scan range
                    for (int st = 0; st < 6; st++) { for (int k = 0; k < 128 && nb < 512; k++) if (S.tex[st][k]) bound[nb++] = h_ser(S.tex[st][k]);
                                                     for (int k = 0; k < 32 && nb < 512; k++) if (S.img[st][k]) bound[nb++] = h_ser(S.img[st][k]); }
                    for (int k = 0; k < nbh && nb < 512; k++) bound[nb++] = h_ser(bh[k]);
                    for (int gi = 0; gi < ng; gi++) {   // Disjoint and not bound
                        grp *g = &G[gi]; if (!g->nops) return;
                        for (int k = 0; k < 9; k++) { if (k < 8 ? !g->clear_c[k] : !(g->clear_d || g->clear_s)) continue;
                            uint64_t ser; int lv, sl; rt_sub(g->rt, k, &ser, &lv, &sl); if (!ser) return;
                            for (int j = 0; j < nb; j++) if (bound[j] == ser) return;
                            for (int m = 0; m < 9; m++) { uint64_t s2; int l2, sl2; if (m < 8 && m >= R.rt.n) continue; rt_sub(&R.rt, m, &s2, &l2, &sl2);
                                if (s2 == ser && l2 == lv && sl2 == sl) return; } } }
                    // Register all skip entries first, then execute: when a hoisted render pass ends the store lookahead scans forward, and the clears at their original positions must already be in the skip set
                    for (int gi = 0; gi < ng; gi++) { g_hoist_skip[g_hoist_n++] = G[gi].rt_op; for (int k = 0; k < G[gi].nops; k++) g_hoist_skip[g_hoist_n++] = G[gi].ops[k]; }
                    p_set_rt rt0 = R.rt; p_scissor sc0 = R.sc; int hs0 = R.has_sc;   // This render pass's targets, scissor and pending clears: restored as they were after execution
                    uint8_t cc0f[8]; MTLClearColor cc0[8]; uint8_t cd0f = R.clear_d, cs0f = R.clear_s; double cd0 = R.cd; uint32_t cs0 = R.cs;
                    memcpy(cc0f, R.clear_c, 8); memcpy(cc0, R.cc, sizeof cc0);
                    for (int gi = 0; gi < ng; gi++) {   // Execute: temporarily swap in that group's targets and clears and open a clear-only render pass
                        grp *g = &G[gi];
                        R.rt = *g->rt; memcpy(R.clear_c, g->clear_c, 8); memcpy(R.cc, g->cc, sizeof R.cc); R.clear_d = g->clear_d; R.clear_s = g->clear_s; R.cd = g->cd; R.cs = g->cs;
                        R.sc = g->sc; R.has_sc = g->has_sc;
                        PD("H %llu hoisted pure-clear pass (original position after this pass)", g_stat_pass + 1);
                        rp_begin_ex(1); rp_end();
                    }
                    R.rt = rt0; R.sc = sc0; R.has_sc = hs0; memcpy(R.clear_c, cc0f, 8); memcpy(R.cc, cc0, sizeof cc0); R.clear_d = cd0f; R.clear_s = cs0f; R.cd = cd0; R.cs = cs0;
                    if (!g_hoist_groups) MLOG("pure-clear pass hoist: first case %d groups (before pass %llu)", ng, g_stat_pass + 1);
                    g_hoist_groups += (uint64_t)ng;
                    return;
                }
                if (in_grp && !G[ng - 1].nops) return;   // The previous group has no clear (only set targets): not recognized
                if (ng >= 4) return;
                memset(&G[ng], 0, sizeof G[ng]); G[ng].rt_op = p; G[ng].rt = r; ng++; in_grp = 1; break; }
            default: break;
        }
        p += h.size;
    }
}
// ---------- Readable tile render pass merge (merge B step 2) ----------
// When a draw of the later pass samples, at the same pixel, a color attachment written by the earlier pass, the two passes are merged into one render pass: what the earlier pass wrote stays in the tile,
// and the later pass reads it directly with the readable tile version (<key>_bf, function-constant specialization), instead of first landing in main memory and being read back just to be sampled.
// Planning (fuse_try, at the start of the earlier pass) does only structural checks; the closed-form proof of same-pixel addressing is done at every draw of the later pass (fz_p2_draw), and if it cannot be proven the merged render pass is ended and
// a normal render pass is reopened with the later pass's original targets (the earlier pass's result is stored as usual, equivalent to not merging).
static void fz_unskip(void) { for (int i = 0; i < g_fz.nskip; i++) for (int j = 0; j < g_hoist_n; j++) if (g_hoist_skip[j] == g_fz.skip[i]) { g_hoist_skip[j] = g_hoist_skip[--g_hoist_n]; break; } }
static int fz_reuse_op(const uint8_t *p) { for (int i = 0; i < g_fz.nreuse; i++) if (g_fz.reuse[i] == p) return 1; return 0; }
// Diagnostic DM_NVN_FUSE_CHECK=1: in-run double rendering. For the later pass's draws that can be proven, keep a state snapshot per draw; after the merged render pass ends, make a copy of the attachments the later pass wrote (the merge path's result),
// then turn off all lookahead and redraw one by one through the normal path with the later pass's original targets and original clears, and compare the two byte by byte (same frame, same input, no dependence on cross-run determinism). The redraw result is left on the attachment (no effect if identical)
static int fz_check_on(void) { static int v = -1; if (v < 0) v = getenv("DM_NVN_FUSE_CHECK") != NULL; return v; }
typedef struct { int idx; p_draw dw; p_draw_idx di; p_scissor sc; int has_sc; void *S_; } fz_snap;
static fz_snap g_fzs[8]; static int g_nfzs, g_fzs_bad, g_fz_checking; static uint64_t g_fzc_same, g_fzc_diff;
static void draw(const p_draw *dw, const p_draw_idx *di);
static void fz_snap_take(const p_draw *dw, const p_draw_idx *di) {
    if (g_nfzs >= 8) { g_fzs_bad = 1; return; }
    fz_snap *z = &g_fzs[g_nfzs++]; z->idx = di != NULL; if (dw) z->dw = *dw; if (di) z->di = *di; z->sc = R.sc; z->has_sc = R.has_sc;
    z->S_ = malloc(sizeof S); memcpy(z->S_, &S, sizeof S);
}
static void fz_check_run(const fuse_t *fz) {
    if (!g_nfzs || g_fzs_bad) { if (g_fzs_bad) MLOG("[red] in-run double render: the later pass has more than 8 draws, not compared"); goto out; }
    {
    id<MTLTexture> att[8], scr[8]; uint64_t sers[8]; int na = 0;
    // fz_end has already restored R.rt from the physical union to the later pass's logical targets; wrote is still registered by physical slot and must be aligned through p2map.
    for (int j = 0; j < fz->rt2.n && j < 8; j++) if (fz->p2map[j] >= 0 && fz->wrote[fz->p2map[j]] && fz->rt2.color[j]) {
        id<MTLTexture> t = tex_mtl(fz->rt2.color[j]); if (!t) continue;
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:t.pixelFormat width:t.width height:t.height mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead; d.storageMode = MTLStorageModePrivate;
        id<MTLTexture> c = [g_dev newTextureWithDescriptor:d]; if (!c) continue;
        enc_b_copy_texture(blit(), t, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(t.width, t.height, 1), c, 0, 0, MTLOriginMake(0, 0, 0));
        att[na] = t; scr[na] = c; sers[na] = fz->rt2.color[j]->serial; na++; }
    if (!na) { MLOG("[red] in-run double render: %d draw snapshots kept, but no comparable attachment", g_nfzs); goto out; }
    static typeof(S) Ssave; memcpy(&Ssave, &S, sizeof S); typeof(R) Rsave = R; const uint8_t *en0 = g_exec_next;
    g_fz_checking = 1; g_exec_next = NULL;   // Turn off all lookahead during the redraw (continuation / hoisting / merging / depth-stencil on demand): normal path
    R.rt = fz->rt2; memcpy(R.clear_c, fz->clr2, 8); memcpy(R.cc, fz->cc2, sizeof R.cc); R.clear_d = fz->cd2f; R.clear_s = fz->cs2f; R.cd = fz->cd2; R.cs = fz->cs2;
    for (int i = 0; i < g_nfzs; i++) { fz_snap *z = &g_fzs[i]; memcpy(&S, z->S_, sizeof S); args_dirty_all(); R.sc = z->sc; R.has_sc = z->has_sc; g_pso_dirty = g_dss_dirty = 1;
        draw(z->idx ? NULL : &z->dw, z->idx ? &z->di : NULL); }
    rp_end();
    memcpy(&S, &Ssave, sizeof S); args_dirty_all(); R = Rsave; g_exec_next = en0; g_fz_checking = 0; g_pso_dirty = g_dss_dirty = 1;
    for (int a = 0; a < na; a++) {
        id<MTLTexture> t = att[a], c = scr[a]; NSUInteger W = t.width, H = t.height, bpp = (NSUInteger)(att_bytes(t, 0) / (W * H));
        id<MTLBuffer> b1 = [g_dev newBufferWithLength:W * H * bpp options:MTLResourceStorageModeShared], b2 = [g_dev newBufferWithLength:W * H * bpp options:MTLResourceStorageModeShared];
        BENC b = blit();
        enc_b_copy_texture_buffer(b, c, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(W, H, 1), b1, 0, W * bpp, W * H * bpp);
        enc_b_copy_texture_buffer(b, t, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(W, H, 1), b2, 0, W * bpp, W * H * bpp);
        unsigned long long ser = sers[a], pass = g_stat_pass, frame = atomic_load(&g_cur_frame); NSUInteger nb = W * H * bpp;
        [g_commit_blocks addObject:^{
            const uint8_t *x = b1.contents, *y = b2.contents; uint64_t dpx = 0, maxd = 0;
            for (NSUInteger k = 0; k < nb; k += bpp) if (memcmp(x + k, y + k, bpp)) { dpx++; for (NSUInteger q = 0; q < bpp; q++) { uint64_t dd = (uint64_t)abs((int)x[k + q] - (int)y[k + q]); if (dd > maxd) maxd = dd; } }
            if (dpx) { g_fzc_diff++; MLOG("[red] in-run double render: frame %llu pass %llu attachment ser=%llu merged vs normal differing pixels %llu / %lu (max per-byte difference %llu)", frame, pass, ser, (unsigned long long)dpx, (unsigned long)(nb / bpp), (unsigned long long)maxd); }
            else { g_fzc_same++; MLOG("in-run double render: frame %llu pass %llu attachment ser=%llu merged vs normal byte-identical (%lu pixels)", frame, pass, ser, (unsigned long)(nb / bpp)); }
            if ((g_fzc_same + g_fzc_diff) % 300 == 0) MLOG("in-run double render totals: byte-identical %llu times, different %llu times", (unsigned long long)g_fzc_same, (unsigned long long)g_fzc_diff);
        }];
    }
    }
out:
    for (int i = 0; i < g_nfzs; i++) free(g_fzs[i].S_);
    g_nfzs = 0; g_fzs_bad = 0;
}
static void fz_end(void) {   // End of a merged render pass (called by rp_end): interrupted before entering the later pass -> retract the skip entries and restore the targets to the earlier pass's; otherwise restore to the later pass's
    if (!g_fz.active) return;
    if (g_fz.phase == 1) { fz_unskip(); R.rt = g_fz.rt1; } else R.rt = g_fz.rt2;
    g_fz.active = 0;
    if (g_fz.phase == 2 && fz_check_on() && !g_fz_checking) { fuse_t fz = g_fz; R.rt = fz.rt2; fz_check_run(&fz); }
    else { for (int i = 0; i < g_nfzs; i++) free(g_fzs[i].S_); g_nfzs = 0; g_fzs_bad = 0; }
}
static int sub_eq(const p_set_rt *a, int ka, const p_set_rt *b, int kb) { uint64_t s1, s2; int l1, l2, x1, x2; rt_sub(a, ka, &s1, &l1, &x1); rt_sub(b, kb, &s2, &l2, &x2); return s1 && s1 == s2 && l1 == l2 && x1 == x2; }
static int prog_samples_ser(const prog_t *pg, uint64_t tex[6][128], uint64_t img[6][32], uint64_t ser) {   // Whether this texture is bound in any texture / image / typed buffer slot declared by the program's reflection
    __unsafe_unretained NvProg *pr = pg ? prog_get(pg) : nil; if (!pr) return 1;
    for (int st = 0; st < 5; st++) { __unsafe_unretained NvShader *sh = pr->sh[st]; if (!sh || sh->stage >= 6) continue;
        for (int i = 0; i < sh->rf.nb; i++) { const nvn_rbind *b = &sh->rf.b[i]; uint64_t h;
            if (b->kind == NVN_RB_IMG) h = b->reg < 32 ? img[sh->stage][b->reg] : 0; else if (b->kind == NVN_RB_TEX || b->kind == NVN_RB_TBUF) h = b->reg < 128 ? tex[sh->stage][b->reg] : 0; else continue;
            if (h && h_ser(h) == ser) return 1; } }
    return 0;
}
static int g_defer_env_ab, g_defer_env_off;   // Environment switches: read once at the start of each submit (defer_reset); the hot path does not call getenv
static void defer_env(void) { const char *x = getenv("DM_NVN_DEFER_AB"), *e = getenv("DM_NVN_DEFER"); g_defer_env_ab = x && !strcmp(x, "1"); g_defer_env_off = e && !strcmp(e, "0"); }
static int defer_on(void) {
    if (!g_defer_env_ab) return tbdr_on() && !g_defer_env_off;
    if (g_defer_ab < 0) { g_defer_ab = 0; g_defer_ab_on = 0; }
    return tbdr_on() && (g_defer_ab || g_defer_ab_on); }
static int defer_handle_sub(uint64_t h, const p_set_rt *r, int k, int cover) {
    int tid = (int)(h & 0xfffff); if (!tid || tid >= g_ntreg || !g_treg[tid].ok) return 0;
    uint64_t ser; int lv, sl; rt_sub(r, k, &ser, &lv, &sl); if (!ser || g_treg[tid].t.serial != ser) return 0;
    if (!g_treg[tid].has_v || !g_treg[tid].v.set_levels) return cover;
    view_t v = g_treg[tid].v; int n = v.nlevels > 0 ? v.nlevels : 1;
    return lv >= v.base_level && lv < v.base_level + n && (!v.set_layers || (sl >= v.min_layer && sl < v.min_layer + (v.nlayers > 0 ? v.nlayers : 1)));
}
static int defer_prog_hits(const prog_t *pg, uint64_t tex[6][128], uint64_t img[6][32], const p_set_rt *r, int color_only, int cover) {
    __unsafe_unretained NvProg *pr = pg ? prog_get(pg) : nil; if (!pr) return 1;
    for (int st = 0; st < 5; st++) { __unsafe_unretained NvShader *sh = pr->sh[st]; if (!sh || sh->stage < 0 || sh->stage >= 6) continue;
        for (int i = 0; i < sh->rf.nb; i++) { const nvn_rbind *b = &sh->rf.b[i]; uint64_t h = 0;
            if (b->kind == NVN_RB_IMG) h = b->reg < 32 ? img[sh->stage][b->reg] : 0;
            else if (b->kind == NVN_RB_TEX || b->kind == NVN_RB_TBUF) h = b->reg < 128 ? tex[sh->stage][b->reg] : 0;
            else continue;
            if (!h) continue;
            for (int k = 0; k < (color_only ? r->n : 9); k++) if ((color_only ? r->color[k] : (k < 8 ? r->color[k] : r->depth)) && defer_handle_sub(h, r, k, cover)) return 1;
        }
    }
    return 0;
}
static void defer_collect_reads(defer_t *d, const prog_t *pg, uint64_t tex[6][128], uint64_t img[6][32]) {
    __unsafe_unretained NvProg *pr = pg ? prog_get(pg) : nil; if (!pr) { d->nreads = 513; return; }
    for (int st = 0; st < 5; st++) { __unsafe_unretained NvShader *sh = pr->sh[st]; if (!sh || sh->stage < 0 || sh->stage >= 6) continue;
        for (int i = 0; i < sh->rf.nb; i++) { const nvn_rbind *b = &sh->rf.b[i]; uint64_t h = 0;
            if (b->kind == NVN_RB_IMG) h = b->reg < 32 ? img[sh->stage][b->reg] : 0;
            else if (b->kind == NVN_RB_TEX || b->kind == NVN_RB_TBUF) h = b->reg < 128 ? tex[sh->stage][b->reg] : 0;
            else continue;
            if (!h) continue; int seen = 0; for (int j = 0; j < d->nreads; j++) seen |= d->p_reads[j] == h;
            if (!seen && d->nreads < 512) d->p_reads[d->nreads++] = h;
        }
    }
}
static int defer_rt_hits_reads(const p_set_rt *r, int idx) {
    if (idx < 0 || idx >= r->n || !r->color[idx]) return 0;
    for (int i = 0; i < g_defer.nreads; i++) if (defer_handle_sub(g_defer.p_reads[i], r, idx, 1)) return 1;
    return 0;
}
static int defer_q_superset(const p_set_rt *q) {
    memset(g_defer.lmap, 0xff, sizeof g_defer.lmap);
    for (int i = 0; i < g_defer.p_rt.n; i++) if (g_defer.p_rt.color[i]) { int found = 0;
        // The indices must be the same: a normal fragment function's color(n) output is written to physical attachment n, and lmap only changes the write mask / blend and cannot move the output (only the _bf version with output mapping constants can).
        // With different indices, deferral would write P's output into a different attachment of Q.
        if (i < q->n && q->color[i] && sub_eq(&g_defer.p_rt, i, q, i)) { g_defer.lmap[i] = (uint8_t)i; found = 1; }
        if (!found) return 0;
    }
    return 1;
}
static int defer_take(const p_draw *dw, const p_draw_idx *di) {
    if (g_defer.n >= 64) { g_defer.reason = 20; return 0; }
    defer_snap *z = &g_defer.snap[g_defer.n++]; z->idx = di != NULL; if (dw) z->dw = *dw; if (di) z->di = *di;
    z->sc = R.sc; z->has_sc = R.has_sc; z->S_ = malloc(sizeof S); memcpy(z->S_, &S, sizeof S); for (int k = 0; k < 8; k++) z->pm[k] = (uint8_t)k; g_defer_draws++; return 1;
}
static void defer_release(void) { defer_release_one(&g_defer); }
static void defer_env(void);
static void defer_reset(void) { defer_clear_all(); g_defer_replaying = 0; defer_env(); }
static void defer_apply_p_clear(void) {
    memset(R.clear_c, 0, sizeof R.clear_c); R.clear_d = R.clear_s = 0;
    for (int j = 0; j < g_defer.q_rt.n; j++) { int i = g_defer.lmap[j]; if (i >= 0 && g_defer.clear_c[i]) { R.clear_c[j] = 1; R.cc[j] = g_defer.cc[i]; } }
    if (g_defer.clear_d) { R.clear_d = 1; R.cd = g_defer.cd; } if (g_defer.clear_s) { R.clear_s = 1; R.cs = g_defer.cs; }
}
static int defer_begin_q(const uint8_t *op) {
    int found = 0, first = -1;
    for (int i = 0; i < 4; i++) if (g_defer_slots[i].active && !g_defer_slots[i].at_q && g_defer_slots[i].q_op == op) { found = 1; if (first < 0) first = i; }
    if (!found) return 0;
    rp_flush();
    g_defer_cur = &g_defer_slots[first]; R.rt = g_defer.q_rt; R.has_rt = 1;
    for (int i = 0; i < 4 && !R.rt.depth; i++) { const defer_t *d = &g_defer_slots[i]; if (d->active && !d->at_q && d->q_op == op && d->q_rt.depth) { R.rt.depth = d->q_rt.depth; R.rt.dview = d->q_rt.dview; R.rt.has_dview = d->q_rt.has_dview; } }   // Attach the depth-stencil needed by any group (the depths of groups with the same Q have been checked compatible)
    memset(R.clear_c, 0, sizeof R.clear_c); R.clear_d = R.clear_s = 0;
    for (int i = 0; i < 4; i++) { defer_t *d = &g_defer_slots[i]; if (!d->active || d->at_q || d->q_op != op) continue;
        for (int j = 0; j < d->q_rt.n; j++) { int k = d->lmap[j]; if (k >= 0 && d->clear_c[k]) { R.clear_c[j] = 1; R.cc[j] = d->cc[k]; } }
        if (d->clear_d) { R.clear_d = 1; R.cd = d->cd; } if (d->clear_s) { R.clear_s = 1; R.cs = d->cs; }
        d->at_q = 1; g_defer_natq++;
    }
    return 1;
}
static void defer_replay(void) {
    if (g_defer_replaying) return;
    int any = 0; for (int i = 0; i < 4; i++) if (g_defer_slots[i].active && g_defer_slots[i].at_q) any = 1;
    if (!any) return;
    typeof(S) save; memcpy(&save, &S, sizeof S); p_scissor sc = R.sc; int has_sc = R.has_sc; int vis = g_vis_counting;
    const uint8_t *en0 = g_exec_next; g_defer_replaying = 1; g_exec_next = NULL;
    for (int gi, after = 0; (gi = defer_next(1, after)) >= 0;) { defer_t *d = &g_defer_slots[gi]; after = d->born;   // In creation order: the groups' P ranges do not overlap and are arranged in sequence, so the group order is the original draw order
        g_defer_cur = d; if (d->reset_between) g_vis_counting = 0;
        { static int once; if (!once++) MLOG("deferred merged pass: first case pass %llu, group %d replayed %d draws", g_stat_pass, gi, d->n); }   // With multiple groups, several groups may already have been created before the first replay, so it cannot be judged by g_defer_n == 1
        for (int i = 0; i < d->n; i++) { defer_snap *z = &d->snap[i]; static uint8_t lm[8]; for (int j = 0; j < 8; j++) lm[j] = d->lmap[j] == 0xff || d->lmap[j] >= 8 ? 0xff : z->pm[d->lmap[j]];
            memcpy(&S, z->S_, sizeof S); args_dirty_all(); R.sc = z->sc; R.has_sc = z->has_sc; g_pso_dirty = g_dss_dirty = 1; g_pso_lmap = lm; draw(z->idx ? NULL : &z->dw, z->idx ? &z->di : NULL); }
        defer_release_one(d);
    }
    g_vis_counting = vis; memcpy(&S, &save, sizeof S); args_dirty_all(); R.sc = sc; R.has_sc = has_sc; g_pso_lmap = NULL; g_pso_fsfn = nil; memset(&g_pso_fz, 0, sizeof g_pso_fz); g_pso_dirty = g_dss_dirty = 1; g_exec_next = en0; g_defer_replaying = 0; g_defer_cur = &g_defer_slots[0];
}
static void defer_fallback(void) {
    if (g_defer_replaying || !defer_has_active()) return;
    g_defer_fallbacks++; MLOG("[red] deferred merged pass: groups still not replayed at the end of the submit, falling back to each group's original P targets");
    if (g_enc) { enc_r_end(g_enc); g_enc = nil; }
    typeof(S) save; memcpy(&save, &S, sizeof S); p_set_rt rt = R.rt; g_defer_replaying = 1;
    for (int gi, after = 0; (gi = defer_next(0, after)) >= 0;) { defer_t *d = &g_defer_slots[gi]; after = d->born; g_defer_cur = d; R.rt = d->p_rt; R.has_rt = 1; memcpy(R.clear_c, d->clear_c, 8); memcpy(R.cc, d->cc, sizeof R.cc);
        R.clear_d = d->clear_d; R.clear_s = d->clear_s; R.cd = d->cd; R.cs = d->cs;
        for (int i = 0; i < d->n; i++) { defer_snap *z = &d->snap[i]; memcpy(&S, z->S_, sizeof S); args_dirty_all(); R.sc = z->sc; R.has_sc = z->has_sc; g_pso_dirty = g_dss_dirty = 1; g_pso_lmap = z->pm; draw(z->idx ? NULL : &z->dw, z->idx ? &z->di : NULL); }
        rp_end(); defer_release_one(d);
    }
    memcpy(&S, &save, sizeof S); args_dirty_all(); R.rt = rt; g_defer_replaying = 0; g_defer_cur = &g_defer_slots[0];
}
static const uint8_t *defer_cont(int *ci) {   // The next segment after a list ends (within the same submit): first the caller return stack, then the remaining handles of this submit; returns NULL when there are none left
    for (;;) { int k = (*ci)++;
        if (k < g_ret_n) { if (g_ret_n > 16) return NULL; return g_ret[g_ret_n - 1 - k]; }
        k -= g_ret_n; if (k < g_nrest) return (const uint8_t *)g_rest[k];
        return NULL; }
}
// Deferral pre-screen (binary search on the store lookahead index, zero scanning): for every color subresource of P, the first "used as attachment / cleared" event after this draw must be "used as attachment under a different SetRenderTargets,
// whose targets cover all of P's colors"; cleared first / never used as attachment again in this submit -> deferral is impossible, return directly. Read events carry no level; handed to the full lookahead to check by level.
static int defer_pre(void) {
    if (!g_sdx_ok || !g_exec_cur || !g_exec_seq || g_sdx_op[g_exec_seq - 1] != g_exec_cur) return 0;
    uint32_t P = g_exec_seq - 1;
    for (int k = 0; k < R.rt.n; k++) { if (!R.rt.color[k]) continue;
        uint64_t ser; int lv, sl; rt_sub(&R.rt, k, &ser, &lv, &sl);
        int b = sdx_bucket(ser, 0); if (b < 0) return 0;
        uint32_t lo = g_sdx_bst[b], end = g_sdx_bst[b + 1], hi = end;
        while (lo < hi) { uint32_t m = (lo + hi) / 2; if (g_sdx[m].seq <= P) lo = m + 1; else hi = m; }
        int ok = 0, same = 0; uint32_t walk = 0, prt = lo > g_sdx_bst[b] && g_sdx[lo - 1].seq == P ? g_sdx[lo - 1].rtseq : SDX_NONE;   // SetRenderTargets sequence number of P's own render pass (taken from this draw's used-as-attachment event)
        for (uint32_t j = lo; j < end; j++) { const sdx_ev *e = &g_sdx[j];
            if (++walk > 64) return 0;   // Too many events (a heavily sampled texture): not taken as a candidate, conservative and avoids a long walk
            if (g_hoist_n && hoist_skipped(e->op)) continue;
            if (e->kind == SDX_READ || e->kind == SDX_NEED) continue;   // Read events carry no level (reading another level is not a conflict); handed to the full lookahead to check by level
            if (e->plane != 0 || e->lv != lv || e->sl != sl) continue;
            if (e->kind == SDX_CLEAR) return 0;
            if (e->rtseq == SDX_NONE || e->rtseq >= g_sdx_nop) return 0;
            const uint8_t *rop = g_sdx_op[e->rtseq]; const p_set_rt *r = (const p_set_rt *)(rop + 8);
            if (rt_same(r, &R.rt)) { if (e->rtseq != prt) same = 1; continue; }   // Same target: one immediately following is a continuation segment of P, one separated by other render passes is Q; the pre-screen does not distinguish them, and if there is still no other candidate at the end it is handed to the full lookahead
            for (int i = 0; i < R.rt.n; i++) { if (!R.rt.color[i]) continue; int f = 0;
                for (int q = 0; q < r->n && !f; q++) if (r->color[q] && sub_eq(&R.rt, i, r, q)) f = 1;
                if (!f) return 0; }
            ok = 1; break; }
        if (!ok && !same) return 0; }
    return 1;
}
static void defer_try(const p_draw *dw, const p_draw_idx *di) {
    if (!defer_on() || defer_has_in_p() || g_defer_replaying || g_fz.active || g_fz_checking || !g_exec_next || !R.rt.n) return;
    int slot = defer_slot_free(); if (slot < 0) return;
    g_defer_cur = &g_defer_slots[slot];
    int ncol = 0; for (int i = 0; i < R.rt.n; i++) ncol += R.rt.color[i] != NULL; if (!ncol) return;   // Render passes with only depth-stencil attached (shadow maps etc.): Q is defined as covering P's colors, so a P without color can never be deferred -- previously the pre-screen let it through idly and the full lookahead scanned dozens of draws for nothing
    int has_clear = R.clear_d || R.clear_s; for (int i = 0; i < 8; i++) has_clear |= R.clear_c[i]; if (!has_clear) return;
    if (!defer_pre()) return;
    memset(&g_defer, 0, sizeof g_defer); g_defer.p_rt = R.rt; memcpy(g_defer.clear_c, R.clear_c, 8); memcpy(g_defer.cc, R.cc, sizeof R.cc);
    g_defer.clear_d = R.clear_d; g_defer.clear_s = R.clear_s; g_defer.cd = R.cd; g_defer.cs = R.cs;
    uint64_t tex[6][128], img[6][32]; memcpy(tex, S.tex, sizeof tex); memcpy(img, S.img, sizeof img); const prog_t *pg = S.prog; ds_st ds = S.ds;
    const uint8_t *p = g_exec_next, *p_end = NULL, *qop = NULL; const p_set_rt *q = NULL; p_set_rt scan_rt = R.rt; int srt_hit = -1, ci = 0, draws = 1, p_has_draw = 1; defer_collect_reads(&g_defer, pg, tex, img);   // The current draw is P's first
    for (int guard = 0; guard < 200000; guard++) {
        op_hdr h; memcpy(&h, p, sizeof h); const void *a = p + 8;
        if (g_hoist_n && hoist_skipped(p)) { p += h.size; continue; }
        switch (h.op) {
            case OP_END: { const uint8_t *nx = defer_cont(&ci); if (!nx) { g_defer.reason = 1; goto fail; } p = nx; continue; }
            case OP_CALL: g_defer.reason = 2; goto fail;
            case OP_JUMP: memcpy(&p, a, 8); continue;
            case OP_BIND_PROGRAM: pg = prog_bind(pg, ((const p_bind_program *)a)->prog, ((const p_bind_program *)a)->stages); break;
            case OP_BIND_TEX: case OP_BIND_IMG: { const p_bind_handles *b = a; bh_fresh(b); int lim = h.op == OP_BIND_IMG ? 32 : 128;
                if (b->stage >= 0 && b->stage < 6 && b->first >= 0 && b->first + b->n <= lim) for (int k = 0; k < b->n; k++) { if (h.op == OP_BIND_IMG) img[b->stage][b->first + k] = b->h[k]; else tex[b->stage][b->first + k] = b->h[k]; } break; }
            case OP_BIND_STATE: { const p_bind_state *b = a; if (b->kind == 5) memcpy(&ds, b->bytes, sizeof ds); break; }
            case OP_DRAW: case OP_DRAW_IDX:
                if (defer_prog_hits(pg, tex, img, &g_defer.p_rt, 1, 1)) { /* Suggestion: here, after identifying that an output mapping is needed but _bf is missing, call bf_want_note. */ g_defer.reason = 7; goto fail; }
                if (p_end) {   // Draws in the intermediate range: must not write textures P reads, must not write P's depth-stencil (and must not test stencil when P writes stencil)
                    if (srt_hit < 0) { srt_hit = 0; for (int k = 0; k < scan_rt.n && !srt_hit; k++) if (scan_rt.color[k] && defer_rt_hits_reads(&scan_rt, k)) srt_hit = 1; }   // Attachments change only at SetRenderTargets: computed once per segment
                    if (srt_hit) { g_defer.reason = 12; goto fail; }
                    if (scan_rt.depth && g_defer.p_rt.depth && scan_rt.depth->serial == g_defer.p_rt.depth->serial && (ds.dw || (g_defer.p_st && ds.st))) { g_defer.reason = 13; goto fail; }
                    break; }
                draws++; if (draws > 64) { g_defer.reason = 20; goto fail; } p_has_draw = 1; defer_collect_reads(&g_defer, pg, tex, img); g_defer.p_dw |= ds.dw; g_defer.p_st |= ds.st && ((S.st_wmask[0] | S.st_wmask[1]) != 0) && (ds.fail_f != NVN_STENCIL_OP_KEEP || ds.zfail_f != NVN_STENCIL_OP_KEEP || ds.zpass_f != NVN_STENCIL_OP_KEEP || ds.fail_b != NVN_STENCIL_OP_KEEP || ds.zfail_b != NVN_STENCIL_OP_KEEP || ds.zpass_b != NVN_STENCIL_OP_KEEP); if (g_defer.p_dw) { g_defer.reason = 8; goto fail; } break;
            case OP_RESET_COUNTER: g_defer.reset_between = 1; break;
            case OP_COPY_T2T: { const p_copy_t2t *c = a;   // Texture copy: allowed only if neither end touches P's attachments and the destination is not a texture P samples
                uint64_t ss = c->src ? c->src->serial : 0, ds_ = c->dst ? c->dst->serial : 0; int bad = !ss || !ds_;
                for (int k = 0; k < g_defer.p_rt.n && !bad; k++) if (g_defer.p_rt.color[k] && (g_defer.p_rt.color[k]->serial == ss || g_defer.p_rt.color[k]->serial == ds_)) bad = 1;
                if (g_defer.p_rt.depth && (g_defer.p_rt.depth->serial == ss || g_defer.p_rt.depth->serial == ds_)) bad = 1;
                for (int k = 0; k < g_defer.nreads && !bad; k++) if (h_ser(g_defer.p_reads[k]) == ds_) bad = 1;
                if (g_defer.nreads > 512) bad = 1;
                if (bad) { g_defer.reason = 3; g_defer.reason_op = h.op; goto fail; } break; }
            case OP_REPORT_COUNTER: case OP_UPDATE_UB: case OP_COPY_B2B: case OP_COPY_B2T: case OP_COPY_T2B: case OP_CLEAR_TEX: case OP_DISPATCH: case OP_RENDER_ENABLE: g_defer.reason = 3; g_defer.reason_op = h.op; goto fail;
            case OP_CLEAR_COLOR: { const p_clear_color *c = a; if (!p_end) { g_defer.reason = 16; goto fail; }   // A clear inside P's continuation segment: do not defer
                if (c->index >= 0 && c->index < scan_rt.n && (defer_rt_hits_reads(&scan_rt, c->index) || (scan_rt.color[c->index] && defer_rt_hits_reads(&g_defer.p_rt, c->index)))) { g_defer.reason = 5; goto fail; } break; }
            case OP_CLEAR_DS: if (!p_end) { g_defer.reason = 16; goto fail; } break;
            case OP_SET_RT: { const p_set_rt *r = a;
                if (!p_end && rt_same(r, &g_defer.p_rt)) break;   // The same target set once more (the game often sends it repeatedly): still a continuation segment of P, and its draws are deferred together
                if (!p_end) p_end = p; int shared = 0; for (int i = 0; i < g_defer.p_rt.n; i++) for (int j = 0; j < r->n; j++) if (g_defer.p_rt.color[i] && r->color[j] && sub_eq(&g_defer.p_rt, i, r, j)) shared = 1;
                if (shared) {   // An empty render pass (targets set, then changed again without drawing or clearing) touches no attachment: it is neither taken as Q nor counted as a conflict
                    const uint8_t *e = p + h.size; int ec = ci, empty = 0;
                    for (int g2 = 0; g2 < 200000; g2++) { op_hdr he; memcpy(&he, e, sizeof he);
                        if (he.op == OP_JUMP) { memcpy(&e, e + 8, 8); continue; }
                        if (he.op == OP_END) { const uint8_t *nx = defer_cont(&ec); if (!nx) break; e = nx; continue; }
                        if (he.op == OP_SET_RT) { empty = 1; break; }
                        if (he.op == OP_DRAW || he.op == OP_DRAW_IDX || he.op == OP_CLEAR_COLOR || he.op == OP_CLEAR_DS || he.op == OP_CALL || he.op == OP_DISPATCH || he.op == OP_CLEAR_TEX || he.op == OP_COPY_T2T || he.op == OP_COPY_B2T || he.op == OP_COPY_T2B) break;
                        e += he.size; }
                    if (empty) break; }
                if (!shared) break; if (!p_has_draw || !defer_q_superset(r)) { g_defer.reason = 6; goto fail; } q = r; qop = p; goto q_found; }
            default: break;
        }
        if (h.op == OP_SET_RT) { scan_rt = *(const p_set_rt *)a; srt_hit = -1; }
        p += h.size;
    }
fail:
    if (g_defer.reason && passdump()) PD("G %llu rejected reason=%d op=%d", g_stat_pass + 1, g_defer.reason, g_defer.reason_op); memset(&g_defer, 0, sizeof g_defer); return;
q_found:
    p = qop; op_hdr qh; memcpy(&qh, p, sizeof qh); p += qh.size; int q_body = 0, q_clears = 0;   // Binding tracking continues from the main scan's state (does not go back to S at the start of P)
    for (int guard = 0; guard < 200000; guard++) { op_hdr h; memcpy(&h, p, sizeof h); const void *a = p + 8; if (h.op == OP_JUMP) { memcpy(&p, a, 8); continue; }
        // The whole Q segment (up to the next SetRenderTargets / end of list): no draw may sample P's color attachments through a view covering P's level -- after deferral P's result is still in the tile and has not landed in main memory, so sampling would read old content
        if (h.op == OP_DRAW || h.op == OP_DRAW_IDX) { if (defer_prog_hits(pg, tex, img, &g_defer.p_rt, 1, 1)) { g_defer.reason = 14; goto fail; } q_body = 1; p += h.size; continue; }
        if (q_body && (h.op == OP_SET_RT || h.op == OP_END)) break;
        if (!q_body && h.op == OP_END) { const uint8_t *nx = defer_cont(&ci); if (!nx) { g_defer.reason = 9; goto fail; } p = nx; continue; }
        if (h.op == OP_CALL) { g_defer.reason = 9; g_defer.reason_op = h.op; goto fail; }
        // After Q's SetRenderTargets and before its first draw and any clear, another SetRenderTargets arrives (the game sets targets repeatedly, the previous one being an empty render pass): if the new targets still cover P take it as Q, otherwise do not defer
        if (!q_body && h.op == OP_SET_RT && !q_clears) { const p_set_rt *r2 = a; if (!defer_q_superset(r2)) { g_defer.reason = 15; goto fail; } q = r2; qop = p; p += h.size; continue; }
        if (h.op == OP_CLEAR_COLOR || h.op == OP_CLEAR_DS) q_clears = 1;
        if (!q_body && (h.op == OP_END || h.op == OP_SET_RT || h.op == OP_UPDATE_UB || h.op == OP_COPY_B2B || h.op == OP_DISPATCH)) { g_defer.reason = 9; g_defer.reason_op = h.op; goto fail; }
        if (h.op == OP_BIND_PROGRAM) pg = prog_bind(pg, ((const p_bind_program *)a)->prog, ((const p_bind_program *)a)->stages); else if (h.op == OP_BIND_TEX || h.op == OP_BIND_IMG) { const p_bind_handles *b = a; bh_fresh(b); int lim = h.op == OP_BIND_IMG ? 32 : 128; if (b->stage >= 0 && b->stage < 6 && b->first >= 0 && b->first + b->n <= lim) for (int k = 0; k < b->n; k++) { if (h.op == OP_BIND_IMG) img[b->stage][b->first + k] = b->h[k]; else tex[b->stage][b->first + k] = b->h[k]; } }
        else if (h.op == OP_CLEAR_COLOR) { const p_clear_color *c = a; if (c->index >= 0 && c->index < q->n && q->color[c->index]) for (int i = 0; i < g_defer.p_rt.n; i++) if (g_defer.p_rt.color[i] && sub_eq(q, c->index, &g_defer.p_rt, i)) { g_defer.reason = 10; goto fail; } }
        p += h.size;
    }
    if (!q || !defer_q_superset(q) || g_defer.n >= 64) { g_defer.reason = 11; goto fail; }
    for (int i = 0; i < 4; i++) if (&g_defer_slots[i] != &g_defer && g_defer_slots[i].active && g_defer_slots[i].q_op == qop && !defer_same_q_depth(&g_defer_slots[i], q)) { g_defer.reason = 17; goto fail; }
    g_defer.q_rt = *q; if (!q->depth && g_defer.p_rt.depth) { g_defer.q_rt.depth = g_defer.p_rt.depth; g_defer.q_rt.dview = g_defer.p_rt.dview; g_defer.q_rt.has_dview = g_defer.p_rt.has_dview; } { int na = 0; for (int i = 0; i < 4; i++) { const defer_t *d = &g_defer_slots[i]; if (d != &g_defer && d->active && d->at_q) na += d->n; }
      if (na + 1 > 64) { g_defer.reason = 20; goto fail; } }
    g_defer.q_op = qop; g_defer.p_end_op = p_end; g_defer.in_p = 1; g_defer.active = 1; g_defer_nact++; g_defer_pend = p_end; g_defer_n++; g_defer.born = g_defer_n;
    // Chained: this render pass is exactly the Q of upstream groups (they are at_q, waiting to be replayed when this render pass opens), and this render pass is itself deferred as a whole -- the upstream groups are merged into the new group in creation order:
    // the target space of an upstream group = this render pass's targets = the new group's P targets, and the snapshot's mapping is composed as pm' = upstream lmap o pm; the upstream clears are already in R and are carried along with the new group below
    for (int gi, after = 0; (gi = defer_next(1, after)) >= 0;) { defer_t *d = &g_defer_slots[gi]; after = d->born; if (d == &g_defer) continue;
        for (int k = 0; k < 8; k++) if (d->lmap[k] != 0xff && d->lmap[k] != k) { g_defer.reason = 18; goto fail; }   // Only merge in upstream groups with an identity mapping (see defer_q_superset)
        for (int i = 0; i < d->n; i++) { defer_snap z = d->snap[i]; uint8_t pm[8]; for (int k = 0; k < 8; k++) pm[k] = d->lmap[k] == 0xff || d->lmap[k] >= 8 ? 0xff : z.pm[d->lmap[k]];
            memcpy(z.pm, pm, 8); g_defer.snap[g_defer.n++] = z; }
        g_defer.reset_between |= d->reset_between; d->n = 0; defer_release_one(d); } if (!defer_take(dw, di)) { defer_release_one(&g_defer); return; }
    memset(R.clear_c, 0, sizeof R.clear_c); R.clear_d = R.clear_s = 0; PD("G %llu accepted group %d P→Q draws=%d", g_stat_pass + 1, slot, draws);
}
// Pre-screen of the necessary condition for merging (binary search on the submit index, zero scanning on failure): merging requires that "the first draw of the later pass (the next SET_RT with a different target that has not been hoisted)
// samples some color attachment of the earlier pass", i.e. there is an SDX_READ event for that attachment at that draw's sequence number. If not satisfied there is certainly no merge, saving the per-operation scan below;
// only if satisfied does it go through the original planning (the decision is exactly the same as without the pre-screen). When the index is unavailable, plan as before.
static int fz_prefilter(void) {
    if (!g_sdx_ok || !g_exec_seq || g_sdx_op[g_exec_seq - 1] != g_exec_cur) return 1;
    uint32_t P = g_exec_seq - 1, lo = 0, hi = g_rtx_n;
    while (lo < hi) { uint32_t m = (lo + hi) / 2; if (g_rtx_seq[m] <= P) lo = m + 1; else hi = m; }
    for (; lo < g_rtx_n; lo++) { const uint8_t *op = g_sdx_op[g_rtx_seq[lo]]; if (g_hoist_n && hoist_skipped(op)) continue; if (!rt_same(&R.rt, (const p_set_rt *)(op + 8))) break; }
    if (lo >= g_rtx_n) return 0;
    uint32_t r2 = g_rtx_seq[lo], a = 0, b = g_drx_n;
    while (a < b) { uint32_t m = (a + b) / 2; if (g_drx_seq[m] <= r2) a = m + 1; else b = m; }
    if (a >= g_drx_n) return 0;
    uint32_t fd = g_drx_seq[a];
    for (uint32_t k = lo + 1; k < g_rtx_n && g_rtx_seq[k] < fd; k++) if (!(g_hoist_n && hoist_skipped(g_sdx_op[g_rtx_seq[k]]))) return 0;   // The target changes again before the first draw: step two of the original planning gives up as well
    for (int j = 0; j < R.rt.n && j < 8; j++) { if (!R.rt.color[j]) continue; int bk = sdx_bucket(R.rt.color[j]->serial, 0); if (bk < 0) continue;
        uint32_t e0 = g_sdx_bst[bk], e1 = g_sdx_bst[bk + 1];
        while (e0 < e1) { uint32_t m = (e0 + e1) / 2; if (g_sdx[m].seq < fd) e0 = m + 1; else e1 = m; }
        for (; e0 < g_sdx_bst[bk + 1] && g_sdx[e0].seq == fd; e0++) if (g_sdx[e0].kind == SDX_READ) return 1; }
    return 0;
}
static void fuse_try(void) {
    if (g_fz.active || !g_exec_next || g_hoist_n + 12 > HOIST_MAX || !R.rt.n) return;
    if (!fz_prefilter()) return;
    // One: from the earlier pass to the next SetRenderTargets, only draws and state are allowed
    const uint8_t *p = NULL, *r2op = NULL, *reuse[8]; int nreuse = 0; const p_set_rt *r2 = NULL; p_scissor sc = R.sc; int has_sc = R.has_sc;
    fz_cursor cur = {.p = g_exec_next}; op_hdr h; const void *a;
    for (int guard = 0; guard < 200000 && !r2; guard++) {
        if (!fz_next(&cur, &p, &h, &a)) return;
        switch (h.op) {
            case OP_COPY_T2T: case OP_COPY_B2T: case OP_COPY_T2B: case OP_CLEAR_TEX: case OP_DISPATCH:
            case OP_CLEAR_COLOR: case OP_CLEAR_DS: case OP_UPDATE_UB: case OP_COPY_B2B: case OP_RENDER_ENABLE: return;
            case OP_SCISSOR: sc = *(const p_scissor *)a; has_sc = 1; break;
            case OP_SET_RT: {
                int pend = R.clear_d || R.clear_s; for (int i = 0; i < 8; i++) pend |= R.clear_c[i];
                if (rt_same(&R.rt, a)) {
                    if (g_enc_mode == 1 || pend || !R.has_rt || !tbdr_on() || nreuse >= 8) return;
                    reuse[nreuse++] = p; continue;
                }
                r2 = a; r2op = p; continue;
            }
            default: break;
        }
    }
    if (!r2 || rt_same(&R.rt, r2)) return;
    // Two: from the start of the later pass to its first draw, only clears (not clearing shared attachments) and state are allowed
    const uint8_t *cl[8]; int ncl = 0; uint8_t clr[8] = {0}; MTLClearColor cc[8]; int cd_f = 0, cs_f = 0; double cdv = 0; uint32_t csv = 0;
    if (!fz_next(&cur, &p, &h, &a)) return;   // Continue from the cursor of step one (already past the later pass's SET_RT, keeping the cross-handle / return stack position)
    for (int guard = 0; guard < 200000; guard++) {
        if (h.op == OP_DRAW || h.op == OP_DRAW_IDX) break;
        switch (h.op) {
            case OP_COPY_T2T: case OP_COPY_B2T: case OP_COPY_T2B: case OP_CLEAR_TEX: case OP_DISPATCH: case OP_SET_RT: case OP_UPDATE_UB: case OP_COPY_B2B: case OP_RENDER_ENABLE: return;
            case OP_SCISSOR: sc = *(const p_scissor *)a; has_sc = 1; break;
            case OP_CLEAR_COLOR: { const p_clear_color *c = a; if (ncl >= 8 || c->index < 0 || c->index >= r2->n || !r2->color[c->index] || c->mask != 0xf) return;
                const tex_t *t = r2->color[c->index];
                if (has_sc && !(sc.x <= 0 && sc.y <= 0 && sc.x + sc.w >= (int)t->d.width && sc.y + sc.h >= (int)t->d.height)) return;
                clr[c->index] = 1; cc[c->index] = MTLClearColorMake(c->rgba[0], c->rgba[1], c->rgba[2], c->rgba[3]); cl[ncl++] = p; break; }
            case OP_CLEAR_DS: { const p_clear_ds *c = a; if (ncl >= 8 || !r2->depth) return;
                if (c->depth_mask) { cd_f = 1; cdv = c->depth; } if (c->stencil_mask) { cs_f = 1; csv = (uint32_t)c->stencil; } cl[ncl++] = p; break; }
            default: break;
        }
        if (!fz_next(&cur, &p, &h, &a)) return;
    }
    // Three: union of attachments (the earlier pass's attachments keep their original indices, those unique to the later pass are appended), consistent sizes, compatible depth
    p_set_rt U = R.rt; int n = R.rt.n; int8_t p2map[8]; memset(p2map, -1, sizeof p2map);
    for (int k = 0; k < r2->n && k < 8; k++) { if (!r2->color[k]) continue;
        int j = -1; for (int m = 0; m < R.rt.n; m++) if (R.rt.color[m] && sub_eq(&R.rt, m, r2, k)) { j = m; break; }
        if (j < 0) { if (n >= 8) return; j = n++; U.color[j] = r2->color[k]; U.cview[j] = r2->cview[k]; U.has_cview[j] = r2->has_cview[k]; }
        else if (clr[k]) return;   // The start of the later pass wants to clear an attachment the earlier pass is drawing to: after merging this clear has nowhere to go
        p2map[k] = (int8_t)j; }
    U.n = n;
    { uint64_t s0; int l0, x0; rt_sub(&U, 0, &s0, &l0, &x0); if (!U.color[0]) return;
      uint32_t w0 = MAX(U.color[0]->d.width >> l0, 1u), h0 = MAX(U.color[0]->d.height >> l0, 1u);
      for (int j = 1; j < n; j++) { uint64_t s_; int l_, x_; rt_sub(&U, j, &s_, &l_, &x_); if (!U.color[j] || MAX(U.color[j]->d.width >> l_, 1u) != w0 || MAX(U.color[j]->d.height >> l_, 1u) != h0) return; } }
    int depth_from_r2 = 0;
    if (R.rt.depth && r2->depth && !sub_eq(&R.rt, 8, r2, 8)) return;
    if (!R.rt.depth && r2->depth) { U.depth = r2->depth; U.dview = r2->dview; U.has_dview = r2->has_dview; depth_from_r2 = 1; }
    if ((cd_f || cs_f) && !depth_from_r2) return;   // The depth is already in use in the earlier pass: the depth clear at the start of the later pass has nowhere to go
    // Four: draws of the earlier pass must not sample attachments brought in by the later pass; when the depth comes from the later pass, depth-stencil testing must not be enabled
    static uint64_t tex[6][128], img[6][32]; memcpy(tex, S.tex, sizeof tex); memcpy(img, S.img, sizeof img);
    const prog_t *pg = S.prog; ds_st ds = S.ds;
    cur = (fz_cursor){.p = g_exec_next};
    for (;;) {   // The first loop iteration checks the draw that opens the render pass (current state), then checks the draws in the range one by one
        if (depth_from_r2 && (ds.dt || ds.dw || ds.st)) return;
        for (int j = R.rt.n; j < n; j++) if (prog_samples_ser(pg, tex, img, U.color[j]->serial)) return;
        if (depth_from_r2 && prog_samples_ser(pg, tex, img, U.depth->serial)) return;
        for (;;) {
            const uint8_t *q; op_hdr hq; const void *aq;
            if (!fz_next(&cur, &q, &hq, &aq)) return;
            if (q == r2op) goto planned;
            if (hq.op == OP_BIND_PROGRAM) pg = prog_bind(pg, ((const p_bind_program *)aq)->prog, ((const p_bind_program *)aq)->stages);
            else if (hq.op == OP_BIND_STATE) { const p_bind_state *b = aq; if (b->kind == 5) memcpy(&ds, b->bytes, sizeof ds); }
            else if (hq.op == OP_BIND_TEX || hq.op == OP_BIND_IMG) { const p_bind_handles *b = aq; bh_fresh(b); int lim = hq.op == OP_BIND_IMG ? 32 : 128;
                if (b->stage >= 0 && b->stage < 6 && b->first >= 0 && b->first + b->n <= lim) for (int k = 0; k < b->n; k++) { if (hq.op == OP_BIND_IMG) img[b->stage][b->first + k] = b->h[k]; else tex[b->stage][b->first + k] = b->h[k]; } }
            else if (hq.op == OP_DRAW || hq.op == OP_DRAW_IDX) break;
        }
    }
planned:
    {   // Five: pre-screen the first draw of the later pass (static conditions), to avoid attaching the union of attachments for nothing: track the program and texture bindings up to that draw
        const prog_t *pg2 = S.prog; static uint64_t t2[6][128], i2[6][32]; memcpy(t2, S.tex, sizeof t2); memcpy(i2, S.img, sizeof i2);
        cur = (fz_cursor){.p = g_exec_next};
        for (;;) { const uint8_t *q; op_hdr hq; const void *aq; if (!fz_next(&cur, &q, &hq, &aq)) return; if (q == p) break;
            if (hq.op == OP_BIND_PROGRAM) pg2 = prog_bind(pg2, ((const p_bind_program *)aq)->prog, ((const p_bind_program *)aq)->stages);
            else if (hq.op == OP_BIND_TEX || hq.op == OP_BIND_IMG) { const p_bind_handles *b = aq; bh_fresh(b); int lim = hq.op == OP_BIND_IMG ? 32 : 128;
                if (b->stage >= 0 && b->stage < 6 && b->first >= 0 && b->first + b->n <= lim) for (int k = 0; k < b->n; k++) { if (hq.op == OP_BIND_IMG) i2[b->stage][b->first + k] = b->h[k]; else t2[b->stage][b->first + k] = b->h[k]; } }
        }
        NvProg *pr2 = pg2 ? prog_get(pg2) : nil; NvShader *vs2 = pr2 ? pr2->sh[0] : nil, *fs2 = pr2 ? pr2->sh[1] : nil;
        if (!vs2 || !fs2) return;
        int touches = 0;
        for (int st = 0; st < 5; st++) { __unsafe_unretained NvShader *sh = pr2->sh[st]; if (!sh || sh->stage >= 6) continue;
            for (int i = 0; i < sh->rf.nb; i++) { const nvn_rbind *bb = &sh->rf.b[i]; uint64_t h;
                if (bb->kind == NVN_RB_IMG) h = bb->reg < 32 ? i2[sh->stage][bb->reg] : 0; else if (bb->kind == NVN_RB_TEX || bb->kind == NVN_RB_TBUF) h = bb->reg < 128 ? t2[sh->stage][bb->reg] : 0; else continue;
                uint64_t ser = h ? h_ser(h) : 0; if (!ser) continue;
                int j = -1; for (int m = 0; m < R.rt.n; m++) if (R.rt.color[m] && R.rt.color[m]->serial == ser) { j = m; break; }
                if (j < 0) continue;
                if (sh != fs2 || bb->kind != NVN_RB_TEX || (fs2->rf.fc_mixed[bb->reg >> 6] >> (bb->reg & 63) & 1)) return;
                int any = 0;
                for (int c = 0; c < fs2->rf.nfc; c++) if (fs2->rf.fc_reg[c] == bb->reg) { int l = fs2->rf.fc_locn[c];
                    if (l >= 32 || (vs2->rf.uv_attr[l] < 0 && vs2->rf.uv_aff_attr[l] < 0)) return; any = 1; }
                if (!any) return;
                touches = 1; } }
        if (!touches) return;   // The later pass does not read the earlier pass's attachments: merging has no benefit
        int ident = 1; for (int c = 0; c < 8; c++) if (fs2->rf.color_mask >> c & 1) { if (p2map[c] < 0) return; if (p2map[c] != c) ident = 0; }
        if (!ident && !fs2->rf.nfo) return;
    }
    memset(&g_fz, 0, sizeof g_fz);
    g_fz.active = 1; g_fz.phase = 1; g_fz.n1 = R.rt.n; g_fz.nreuse = nreuse; g_fz.rt1 = R.rt; g_fz.rt2 = *r2; g_fz.rt2_op = r2op; memcpy(g_fz.reuse, reuse, sizeof reuse); memcpy(g_fz.p2map, p2map, 8);
    for (int j = 0; j < 8; j++) g_fz.lmap1[j] = j < R.rt.n ? (uint8_t)j : 0xff;
    fz_probe_cov2(r2, p, p2map, clr, g_fz.n1, n);
    g_fz.skip[g_fz.nskip++] = r2op; for (int i = 0; i < ncl; i++) g_fz.skip[g_fz.nskip++] = cl[i];
    for (int i = 0; i < g_fz.nskip; i++) g_hoist_skip[g_hoist_n++] = g_fz.skip[i];
    R.rt = U;
    memcpy(g_fz.clr2, clr, 8); memcpy(g_fz.cc2, cc, sizeof cc); g_fz.cd2f = (uint8_t)cd_f; g_fz.cs2f = (uint8_t)cs_f; g_fz.cd2 = cdv; g_fz.cs2 = csv;
    for (int k = 0; k < 8; k++) if (clr[k]) { R.clear_c[p2map[k]] = 1; R.cc[p2map[k]] = cc[k]; }
    if (cd_f) { R.clear_d = 1; R.cd = cdv; } if (cs_f) { R.clear_s = 1; R.cs = csv; }
    if (!g_fz_n++) MLOG("readable tile pass merge: first case pass %llu (%d physical attachments)", g_stat_pass + 1, n);
    PD("F %llu merging the next pass (readable tile): %d physical attachments, previous pass %d", g_stat_pass + 1, n, R.rt.n == n ? g_fz.n1 : g_fz.n1);
}
static id<MTLFunction> bf_fn(NvShader *fs, const int *fx, uint8_t fbmask, const uint8_t *lmap) {   // The readable tile version is specialized by constants (cached)
    os_unfair_lock_lock(&g_fz_fn_lock);
    if (!g_bf_fn_cache) { g_bf_fn_cache = [NSMutableDictionary dictionary]; g_bf_lib_cache = [NSMutableDictionary dictionary]; }
    size_t kl = strlen(fs->key); NSString *base = [NSString stringWithFormat:@"%.*s", (int)(kl > 2 ? kl - 2 : kl), fs->key];
    id<MTLLibrary> lib = g_bf_lib_cache[base];
    if (!lib) {
        NSError *e = nil; NSString *path = [NSString stringWithFormat:@"%@/%@_bf.metallib", g_msl_dir, base];
        lib = lib_from_file(path, &e);
        if (!lib) MLOG("[red] failed to load readable tile version %s: %s", path.UTF8String, e.localizedDescription.UTF8String);
        else g_bf_lib_cache[base] = lib;
    }
    if (!lib) { os_unfair_lock_unlock(&g_fz_fn_lock); return nil; }
    NSMutableString *k = [NSMutableString stringWithFormat:@"%02x", fbmask];
    for (int i = 0; i < fs->rf.nfc; i++) [k appendFormat:@",%d", fx[i]];
    for (int j = 0; j < 8; j++) [k appendFormat:@"/%02x", lmap[j]];
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", base, k];
    id<MTLFunction> f = g_bf_fn_cache[cacheKey];
    if (f) { os_unfair_lock_unlock(&g_fz_fn_lock); return f; }
    MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
    for (int i = 0; i < fs->rf.nfc; i++) { int v = fx[i]; [cv setConstantValue:&v type:MTLDataTypeInt atIndex:(NSUInteger)i]; }
    for (int q = 0; q < 8; q++) { bool b = fbmask >> q & 1; [cv setConstantValue:&b type:MTLDataTypeBool atIndex:(NSUInteger)(32 + q)]; }
    for (int j = 0; j < fs->rf.nfo; j++) for (int q = 0; q < 8; q++) { bool b = lmap[q] == fs->rf.fo_color[j]; [cv setConstantValue:&b type:MTLDataTypeBool atIndex:(NSUInteger)(64 + 8 * j + q)]; }
    NSError *e = nil; f = [lib newFunctionWithName:@"main0" constantValues:cv error:&e];
    if (!f) { MLOG("[red] readable tile version specialization failed %s (%s): %s", fs->key, k.UTF8String, e.localizedDescription.UTF8String); os_unfair_lock_unlock(&g_fz_fn_lock); return nil; }
    g_bf_fn_cache[cacheKey] = f; os_unfair_lock_unlock(&g_fz_fn_lock); return f;
}
static int ubo_float(int slot, uint16_t ref, float *out) {   // Component cmp of vector vec of the uniform slot (read on the CPU side; not read if it falls within a buffer write pending execution in this submit)
    int sl = ref >> 8, vec = ref >> 2 & 63, cmp = ref & 3;
    if (slot < 0 || slot >= 6 || sl < 0 || sl >= 16) return 0;
    const p_bind_buf *u = &S.ubo[slot][sl]; uint64_t off = (uint64_t)vec * 16 + (uint64_t)cmp * 4;
    if (!u->addr || off + 4 > u->size) return 0;
    { const us_ent *sc = us_find(u->addr + off, 4); if (sc) { memcpy(out, sc->cpu + (u->addr + off - sc->lo), 4); if (g_nupd) upd_apply(u->addr + off, (uint8_t *)out, 4); return 1; } }   // what the GPU reads
    if (pend_hits(u->addr + off, 4)) return 0;
    void *mb; uint64_t mo; const uint8_t *base;
    if (!mtl_addr(u->addr + off, 4, &mb, &mo) || !(base = [(__bridge id<MTLBuffer>)mb contents])) return 0;
    memcpy(out, base + mo, 4); return 1;
}
static int zskip_fact_for(const char *key, zskip_fact *out) {
    if (!key) return 0;
    for (int i = 0; i < g_zskip_nf; i++) if (!strncmp(key, g_zskip_facts[i].key, strlen(g_zskip_facts[i].key))) { *out = g_zskip_facts[i]; return 1; }   // Runtime keys carry the _b suffix
    return 0;
}
static int zskip_view_zero(int tid) {
    if (!tid || tid >= g_ntreg || !g_treg[tid].ok) return 0;
    treg_t *r = &g_treg[tid]; const tex_t *t = &r->t; int lv0 = r->has_v && r->v.set_levels ? r->v.base_level : 0;
    int nl = r->has_v && r->v.set_levels && r->v.nlevels > 0 ? r->v.nlevels : 1;
    int sl0 = r->has_v && r->v.set_layers ? r->v.min_layer : 0;
    int ns = r->has_v && r->v.set_layers && r->v.nlayers > 0 ? r->v.nlayers : 1;
    for (int l = 0; l < nl; l++) for (int s = 0; s < ns; s++) if (!zskip_has(t->serial, lv0 + l, sl0 + s)) return 0;
    return 1;
}
// While an occlusion query is counting, a skipped draw should have contributed passed samples: it only does not matter if "there is no report before the next reset".
// Looking forward in replay order from after this draw: sample count reset encountered first -> does not matter (return 1); sample count report encountered first, or the end cannot be seen (submit ends) -> matters (return 0)
static int zskip_vis_dead(void) {
    if (!g_vis_counting) return 1;
    const uint8_t *p = g_exec_next; int ci = 0; if (!p) return 0;
    for (int guard = 0; guard < 200000; guard++) { op_hdr h; memcpy(&h, p, sizeof h); const void *a = p + 8;
        if (h.op == OP_JUMP) { memcpy(&p, a, 8); continue; }
        if (h.op == OP_END) { p = defer_cont(&ci); if (!p) return 0; continue; }
        if (h.op == OP_CALL) return 0;
        if (h.op == OP_RESET_COUNTER || h.op == OP_REPORT_COUNTER) { uint64_t t; memcpy(&t, a, 8); if (t == NVN_COUNTER_TYPE_SAMPLES_PASSED) return h.op == OP_RESET_COUNTER; }
        p += h.size; }
    return 0;
}
static int zskip_can_draw(NvProg *pr) {
    // Skip conditions (all must hold): the fragment key is in the fact table, the view bound to every texture slot declared by its reflection covers only subresources known to be all zero, the coefficient is finite,
    // no depth write and no stencil, not counting an occlusion query, and every color attachment to be written is already 0 (a candidate cleared entirely to 0 in this render pass, or known all zero) -- writing 0 over 0.
    // Reasons for not holding (the N line of PASSDUMP): 1 depth / stencil 2 occlusion query counting with a report before the reset 3 coefficient unreadable or non-finite 4 image slot 5 sampled view not known all zero 6 no target 7 target is not 0
    if (!zskip_on() || !pr) return 0;
    NvShader *fs = nil; for (int st = 0; st < 5; st++) if (pr->sh[st] && pr->sh[st]->stage == 1) fs = pr->sh[st];
    zskip_fact f; float coeff; int why = 0;
    if (!fs || !zskip_fact_for(fs->key, &f)) return 0;
    if (S.ds.dw || S.ds.st) why = 1;
    else if (!zskip_vis_dead()) why = 2;
    else if (f.ubo_slot >= 0 && (!ubo_float(1, (uint16_t)((f.ubo_slot << 8) | (f.vec << 2) | f.comp), &coeff) || !isfinite(coeff))) why = 3;   // ubo_slot < 0: this shader has no coefficient
    for (int i = 0; !why && i < fs->rf.nb; i++) { nvn_rbind *b = &fs->rf.b[i];
        if (b->kind == NVN_RB_IMG) { why = 4; break; }
        if (b->kind != NVN_RB_TEX && b->kind != NVN_RB_TBUF) continue;
        int tid = b->reg < 128 ? (int)(S.tex[1][b->reg] & 0xfffff) : 0; if (!zskip_view_zero(tid)) why = 5; }
    if (!why && (!R.has_rt || !R.rt.n)) why = 6;
    for (int i = 0; !why && i < R.rt.n && i < 8; i++) { if (!R.rt.color[i]) continue;
        int pending = g_enc ? g_zskip_cand_ok[i] : zskip_zero_clear(i);   // Render pass already open: look at the candidates noted when the render pass was opened (not yet drawn to); not open: look at the pending clears
        if (!pending && (g_enc || R.clear_c[i] || !zskip_target_zero(R.rt.color[i], &R.rt.cview[i], R.rt.has_cview[i]))) why = 7; }
    if (why) PD("N %llu zero-source not skipped reason=%d set %d", g_stat_pass + 1, why, g_zskip_n);
    return !why;
}
static int uv_proof(NvShader *vs, int locn, const p_draw *dw, const p_draw_idx *di) {   // The interpolated output locn at every pixel center is exactly this pixel's texel center: u = (x + 1) / 2, v = (1 - y) / 2, w = 1, viewport and scissor cover the whole block
    if (locn < 0 || locn >= 32 || vs->rf.pos_attr < 0) return 0;
    int direct = vs->rf.uv_attr[locn] >= 0, aff = vs->rf.uv_aff_attr[locn] >= 0;
    if (!direct && !aff) return 0;
    float sc[4] = {1, 0, 1, 0};   // Pass-through as-is = scale 1, offset 0
    if (!direct) for (int q = 0; q < 4; q++) if (!ubo_float(0, vs->rf.uv_aff[locn][q], &sc[q])) return 0;
    NSUInteger W = g_pass.tw, H = g_pass.th;
    if (S.has_vp && !(S.vp[0][0] == 0 && S.vp[0][1] == 0 && S.vp[0][2] == (float)W && S.vp[0][3] == (float)H)) return 0;
    if (R.has_sc && !(R.sc.x <= 0 && R.sc.y <= 0 && R.sc.x + R.sc.w >= (int)W && R.sc.y + R.sc.h >= (int)H)) return 0;
    float P[64][4], Q[64][4]; int n = dw ? dw->count : di->count;
    if (attr_read(vs->rf.pos_attr, dw, di, P) || attr_read(direct ? vs->rf.uv_attr[locn] : vs->rf.uv_aff_attr[locn], dw, di, Q)) return 0;
    for (int k = 0; k < n; k++) { float w = vs->rf.pos_w1 ? 1.0f : P[k][3];
        float u = direct ? Q[k][0] : fmaf(Q[k][0], sc[0], sc[1]), v = direct ? Q[k][1] : fmaf(Q[k][1], sc[2], sc[3]);   // The same fma as the shader
        if (w != 1.0f || u != (P[k][0] + 1.0f) * 0.5f || v != (1.0f - P[k][1]) * 0.5f) { PD("F %llu uv proof: vertex %d position %g,%g uv %g,%g (scale / offset %g,%g,%g,%g)", g_stat_pass, k, P[k][0], P[k][1], u, v, sc[0], sc[1], sc[2], sc[3]); return 0; } }
    return 1;
}
// One draw of the later pass: verify and produce the specialization. Returns 0 = cannot be proven (the caller ends the merged render pass and reopens with the original targets)
static int fz_p2_draw(NvProg *pr, const p_draw *dw, const p_draw_idx *di, uint8_t lmap[8], __strong id<MTLFunction> *fn) {
    NvShader *vs = pr->sh[0], *fs = pr->sh[1]; *fn = nil;
    if (!vs || !fs) { PD("F %llu not provable: no vertex / fragment shader", g_stat_pass); return 0; }
    if (alpha_on()) { PD("F %llu not provable: the draw has an alpha test (the readable-tile version is not specialized for it)", g_stat_pass); return 0; }
    if (!g_fz.rt2.depth && R.rt.depth && (S.ds.dt || S.ds.dw || S.ds.st)) { PD("F %llu not provable: depth comes from the previous pass and this draw enables depth / stencil testing", g_stat_pass); return 0; }
    int fx[32]; for (int i = 0; i < 32; i++) fx[i] = -1; uint8_t fbmask = 0;
    for (int st = 0; st < 5; st++) { __unsafe_unretained NvShader *sh = pr->sh[st]; if (!sh || sh->stage >= 6) continue;
        for (int i = 0; i < sh->rf.nb; i++) { const nvn_rbind *b = &sh->rf.b[i]; uint64_t h;
            if (b->kind == NVN_RB_IMG) h = b->reg < 32 ? S.img[sh->stage][b->reg] : 0; else if (b->kind == NVN_RB_TEX || b->kind == NVN_RB_TBUF) h = b->reg < 128 ? S.tex[sh->stage][b->reg] : 0; else continue;
            uint64_t ser = h ? h_ser(h) : 0; if (!ser) continue;
            int j = -1; for (int m = 0; m < g_fz.n1; m++) if (R.rt.color[m] && R.rt.color[m]->serial == ser) { j = m; break; }
            if (j < 0) continue;   // What is sampled is not an attachment of the earlier pass
            if (sh != fs || b->kind != NVN_RB_TEX) { PD("F %llu not provable: a non-fragment stage or a non-texture slot reads the previous pass's attachment", g_stat_pass); return 0; }
            if (fs->rf.fc_mixed[b->reg >> 6] >> (b->reg & 63) & 1) { PD("F %llu not provable: slot %d has mixed use", g_stat_pass, b->reg); return 0; }
            uint64_t s_; int lv, sl; rt_sub(&R.rt, j, &s_, &lv, &sl);
            if (lv || sl || MAX(R.rt.color[j]->d.width, 1u) != g_pass.tw || MAX(R.rt.color[j]->d.height, 1u) != g_pass.th) { PD("F %llu not provable: attachment is not level 0 layer 0 or its size does not match", g_stat_pass); return 0; }
            {   // The sampled view must also be exactly the attachment itself (previously only the attachment being level 0 layer 0 was checked, not the view bound by the shader -- when the same texture is sampled through a view of level k / layer k / a changed format,
                // the proof would still hold, the sampling would be changed to read on-tile level 0 / the original format, and the picture would be wrong). The view's starting level / layer must be 0 and its format must equal the attachment's actual format, otherwise do not merge
                int tid_ = (int)(h & 0xfffff); void *tv_ = NULL; if (tid_) tex_fast_rid(tid_, &tv_); __unsafe_unretained id<MTLTexture> tv = (__bridge id<MTLTexture>)tv_;
                uint32_t apf_ = tv.parentTexture ? (uint32_t)tv.parentTexture.pixelFormat : (uint32_t)tv.pixelFormat; uint8_t swz_[4];
                if (R.rt.has_cview[j] && R.rt.cview[j].set_format && !(nvn_fmt_to_mtl(R.rt.cview[j].format, &apf_, swz_) && apf_)) apf_ = 0;   // The attachment is attached through a format-changing view: take that format; if unrecognized, do not merge
                MTLPixelFormat apf = (MTLPixelFormat)apf_;
                if (!tv || (tv.parentTexture && (tv.parentRelativeLevel || tv.parentRelativeSlice)) || tv.pixelFormat != apf) {
                    static int lg; if (lg++ < 8) LOG("[nvn-mtl] on-chip read merge: slot %d sampled view (base level %lu layer %lu format %lu) does not match the attachment (level 0 layer 0 format %lu), not merging (frame %llu pass %llu)", b->reg,
                        tv && tv.parentTexture ? (unsigned long)tv.parentRelativeLevel : 0ul, tv && tv.parentTexture ? (unsigned long)tv.parentRelativeSlice : 0ul, (unsigned long)tv.pixelFormat, (unsigned long)apf,
                        (unsigned long long)atomic_load(&g_cur_frame), g_stat_pass);
                    PD("F %llu not provable: slot %d sampled view is not the attachment itself (level / layer / format mismatch)", g_stat_pass, b->reg); return 0; } }
            int any = 0;
            for (int c = 0; c < fs->rf.nfc; c++) if (fs->rf.fc_reg[c] == b->reg) {
                if (!uv_proof(vs, fs->rf.fc_locn[c], dw, di)) { PD("F %llu not provable: slot %d sample coordinate is not the current pixel (interpolated output %d)", g_stat_pass, b->reg, fs->rf.fc_locn[c]); return 0; }
                fx[c] = j; fbmask |= (uint8_t)(1u << j); any = 1; }
            if (!any) { PD("F %llu not provable: slot %d sample is not in the rewritable table", g_stat_pass, b->reg); return 0; } } }
    memset(lmap, 0xff, 8);
    for (int c = 0; c < 8; c++) if (fs->rf.color_mask >> c & 1) { if (g_fz.p2map[c] < 0) { PD("F %llu not provable: output color %d has no matching attachment", g_stat_pass, c); return 0; } lmap[g_fz.p2map[c]] = (uint8_t)c; }
    int ident = !fbmask; for (int c = 0; c < 8; c++) if ((fs->rf.color_mask >> c & 1) && g_fz.p2map[c] != c) ident = 0;
    if (ident) { for (int q = 0; q < 8; q++) if (lmap[q] != 0xff) g_fz.wrote[q] = 1; if (fz_check_on()) fz_snap_take(dw, di); return 1; }   // Does not read the tile and the output is not shifted: use the original version (the write mask still follows the mapping)
    if (!fs->rf.nfo) { bf_want_note(fs->key); PD("F %llu not provable: no readable tile version (outputs must be shifted)", g_stat_pass); return 0; }
    *fn = bf_fn(fs, fx, fbmask, lmap);
    if (!*fn) return 0;
    memset(&g_fz_desc, 0, sizeof g_fz_desc); g_fz_desc.kind = 1; g_fz_desc.fbmask = fbmask; for (int i = 0; i < 32; i++) g_fz_desc.fx[i] = (int8_t)fx[i];
    for (int q = 0; q < 8; q++) if (lmap[q] != 0xff) g_fz.wrote[q] = 1;
    if (fz_check_on()) fz_snap_take(dw, di);
    g_fz_draws++; return 1;
}
// ---------- 8-bit indices the GPU wrote earlier in this submission (MacNativeGames' widen_u8_gpu, as seedds/nxnative 7dde056 adapted it; both MIT;
// written anew here) ----------
// Metal has no 8-bit index type, so draw widens them to 16 bits on the CPU at replay. When a buffer write encoded earlier in this submission (copy,
// inline update) covers them, the CPU reads the bytes from before that write (Tears of the Kingdom, red line 83). Such a draw is widened on the GPU:
// the render pass ends, a compute pass writes the 16-bit indices into the arena (the restart index 0xff mapped as on the CPU path), and the draw
// opens the pass again. Measured per run (the count below); nxnative batches the following draws up to the next buffer write to split fewer passes
static uint64_t g_wide_gpu, g_wide_runs;   // the current draw's widened indices (0: none); draws widened so far
static uint64_t wide_u8_gpu(const p_draw_idx *di, int r8) {
    static id<MTLComputePipelineState> ps; static int failed; M4_ONLY(static id<MTL4ArgumentTable> at;)
    if (failed) return 0;
    if (!ps) { NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void wide_u8(device const uchar *src [[buffer(0)]], device ushort *dst [[buffer(1)]], constant uint4 &p [[buffer(2)]], uint i [[thread_position_in_grid]]) {\n"
            "    if (i < p.x) { uchar v = src[p.y + i]; dst[i] = p.z && v == 0xff ? ushort(0xffff) : ushort(v); } }\n" options:nil error:&e];
        id<MTLFunction> f = l ? [l newFunctionWithName:@"wide_u8"] : nil; ps = f ? [g_dev newComputePipelineStateWithFunction:f error:&e] : nil;
#if !DM_NVN_M3
        if (ps) { MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 3; at = [g_dev newArgumentTableWithDescriptor:ad error:&e]; }
#endif
        if (!ps M4_ONLY(|| !at)) { failed = 1; MLOG("[red] 8-bit index widening on the GPU: no compute pipeline (%s): widened on the CPU", e.localizedDescription.UTF8String); return 0; } }
    void *mb; uint64_t mo, src;
    if (!mtl_gpu_addr(di->ibuf, (uint64_t)di->count, &mb, &mo, &src)) return 0;
    rp_end(); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    id<MTLBuffer> ob; size_t oo = arena_alloc((size_t)di->count * 2, &ob); id<MTLBuffer> pb; size_t po = arena_alloc(16, &pb);
    uint32_t *p = (uint32_t *)((uint8_t *)pb.contents + po); p[0] = (uint32_t)di->count; p[1] = (uint32_t)(mo & 15); p[2] = (uint32_t)r8; p[3] = 0;
    CENC ce = (CENC)enc_c_begin(NULL);
#if DM_NVN_M3
    [ce setBuffer:(__bridge id<MTLBuffer>)mb offset:(NSUInteger)(mo & ~15ull) atIndex:0]; [ce setBuffer:ob offset:oo atIndex:1]; [ce setBuffer:pb offset:po atIndex:2];
#else
    [ce setArgumentTable:at]; [at setAddress:src - (mo & 15) atIndex:0]; [at setAddress:ob.gpuAddress + oo atIndex:1]; [at setAddress:pb.gpuAddress + po atIndex:2];
#endif
    enc_c_pso(ce, ps); enc_c_dispatch(ce, MTLSizeMake(((NSUInteger)di->count + 63) / 64, 1, 1), MTLSizeMake(64, 1, 1)); enc_c_end(ce);
    args_dirty_all();
    uint64_t n = ++g_wide_runs; if (n <= 4 || !(n % 1000)) MLOG("8-bit indices written by the GPU earlier in this submission widened on the GPU (%llu draws so far; each ends the render pass)", (unsigned long long)n);
    return ob.gpuAddress + oo;
}
// Before a draw opens its render pass: an updated range it reads other than as a uniform buffer (vertex, index, storage buffers, buffer textures), or a
// uniform range without a snapshot, needs the updates in memory first. Not while deferred or merged passes are being built (their draws are replayed
// later in one pass): the copy then still comes out right if a snapshot exists, else reports (upd_shadow)
static void upd_guard_draw(NvProg *pr, const p_draw_idx *di) {   // only what this draw's shaders read (stale bindings of earlier draws do not count)
    int why = -1;
    if (di) { int isz = di->itype == 0 ? 1 : di->itype == 1 ? 2 : 4; if (upd_overlap_seq(di->ibuf, di->ibuf + (uint64_t)di->count * isz)) why = 0; }
    __unsafe_unretained NvShader *vs = pr ? pr->sh[0] : nil;
    for (int v = 0; vs && why < 0 && v < vs->rf.nv; v++) { int a = vs->rf.v[v].nvn; if (a < 0 || a >= 16 || a >= S.nattr || S.attr[a].stream >= 16) continue;
        const NVNbufferRange *r = &S.vbuf[S.attr[a].stream]; if (r->address && upd_overlap_seq(r->address, r->address + (r->size ? r->size : 1))) why = 1; }
    for (int st = 0; st < 5 && why < 0 && pr; st++) { __unsafe_unretained NvShader *sh = pr->sh[st]; if (!sh || sh->stage < 0 || sh->stage >= 5) continue;
        for (int i = 0; i < sh->rf.nb && why < 0; i++) { const nvn_rbind *b = &sh->rf.b[i];
            if (b->kind == NVN_RB_SBUFP && b->reg < 16) { const p_bind_buf *u = &S.ssbo[sh->stage][b->reg]; if (u->addr && upd_overlap_seq(u->addr, u->addr + (u->size ? u->size : 1))) why = 2; }
            else if (b->kind == NVN_RB_TBUF && b->reg < 128) { int tid = (int)(S.tex[sh->stage][b->reg] & 0xfffff); pthread_mutex_lock(&g_rmu);
                if (tid > 0 && tid < g_ntreg && g_treg[tid].ok && g_treg[tid].t.mem) { int bw, bh, bpb = nvn_fmt_bpb(g_treg[tid].t.d.format, &bw, &bh); uint64_t m = (uint64_t)(uintptr_t)g_treg[tid].t.mem;
                    if (upd_overlap_seq(m, m + (uint64_t)g_treg[tid].t.d.width * (bpb ? bpb : 16))) why = 3; }
                pthread_mutex_unlock(&g_rmu); }
            else if (b->kind == NVN_RB_CBUF && b->reg < 16) { const p_bind_buf *u = &S.ubo[sh->stage][b->reg]; if (u->addr && u->size && upd_overlap_seq(u->addr, u->addr + u->size) && !us_find(u->addr, u->size)) why = 4; } } }
    if (why < 0) return;
    if (g_defer_nact || g_fz.active || g_fz_checking) { RED_ONCE(91, "renamed uniform update: a draw reads an updated range while a deferred or merged pass is built (first case): not written first"); return; }
    g_ren_guard++; g_ren_g[why]++; upd_flush();
}
static int lay_reads_target(NvProg *pr);
// Layered passes (see g_lay). Off with the TBDR rewrites (they own pass boundaries), on GPUs without two-view amplification, by DM_NVN_LAYER_MERGE=0
static int lay_on(void) {
    static int v = -1;
    if (v < 0) { const char *e = getenv("DM_NVN_LAYER_MERGE"); v = !(e && !strcmp(e, "0")) && [g_dev supportsVertexAmplificationCount:2]; if (e && !v) MLOG("DM_NVN_LAYER_MERGE=0: layered passes off"); }
    return v && !tbdr_on();
}
static int lay_prim_ok(int prim) { return prim == NVN_DRAW_PRIMITIVE_TRIANGLES || prim == NVN_DRAW_PRIMITIVE_TRIANGLE_STRIP; }   // the triangle topology class a layered pipeline needs
static int lay_same(const p_set_rt *r, uint64_t ser, const view_t *v0) {   // one colour target, the same texture, level and view but for its layer
    if (r->n != 1 || r->depth || !r->color[0] || r->color[0]->serial != ser || !r->has_cview[0]) return 0;
    view_t v = r->cview[0]; if (!v.set_layers || v.nlayers != 1) return 0;
    v.min_layer = v0->min_layer; return !memcmp(&v, v0, sizeof v);
}
static int lay_op_safe(unsigned op) {   // ops that leave a pass open: state and bindings (draws and SetRenderTargets are looked at by the caller)
    switch (op) {
        case OP_VIEWPORTS: case OP_SCISSOR: case OP_DEPTH_RANGE: case OP_BIND_PROGRAM: case OP_BIND_STATE: case OP_BIND_VATTR: case OP_BIND_VSTREAM: case OP_BIND_VBUF:
        case OP_BIND_UBO: case OP_BIND_SSBO: case OP_BIND_TEX: case OP_BIND_SAMP: case OP_BIND_IMG: case OP_STENCIL: case OP_POLY_OFFSET: case OP_BLEND_COLOR: case OP_DEPTH_CLAMP:
        case OP_SET_TEX_POOL: case OP_SET_SAMP_POOL: case OP_BARRIER: case OP_PRIM_RESTART: case OP_BEGIN: return 1;
        default: return 0;
    }
}
// rp_begin_ex: the number of layers of a layered pass starting at *first, or 0. The lookahead only sizes the range: a SetRenderTargets for a layer
// outside it, a clear, any other op and a draw that cannot go to a layer end the pass as before (lay_continue, the clear cases, draw)
static int lay_decide(int clear_only, int *first) {
    if (g_lay.refuse) { g_lay.refuse = 0; return 0; }
    if (clear_only || !lay_on() || g_vis_counting || R.rt.n != 1 || !R.rt.color[0] || R.rt.depth || !R.rt.has_cview[0] || g_defer_replaying || g_defer_nact || g_fz.active) return 0;
    const tex_t *t = R.rt.color[0]; const view_t *v = &R.rt.cview[0];
    if ((t->d.target != NVN_TEXTURE_TARGET_CUBEMAP && t->d.target != NVN_TEXTURE_TARGET_2D_ARRAY && t->d.target != NVN_TEXTURE_TARGET_CUBEMAP_ARRAY) || t->d.samples > 1 || !v->set_layers || v->nlayers != 1) return 0;
    if (R.clear_c[0] || R.clear_d || R.clear_s) return 0;   // a load action would clear every layer of the range
    unsigned lv = v->set_levels ? v->base_level : 0;
    if (mip_extent(t->d.width, lv) > LAY_MAX_EXTENT || mip_extent(t->d.height, lv) > LAY_MAX_EXTENT) return 0;
    if (!(g_fd_dw ? lay_prim_ok(g_fd_dw->prim) : g_fd_di && lay_prim_ok(g_fd_di->prim))) return 0;
    if (!g_exec_next || g_ret_n > 8) return 0;
    fz_cursor cur = {.p = g_exec_next}; for (int k = 0; k < g_ret_n; k++) cur.ret[k] = g_ret[k]; cur.ret_n = g_ret_n;   // the replay's own return stack first
    int lo = v->min_layer, hi = v->min_layer;
    for (int guard = 0; guard < 4096; guard++) {
        const uint8_t *q; op_hdr oh; const void *oa;
        if (!fz_next(&cur, &q, &oh, &oa) || cur.bad) break;
        if (oh.op == OP_SET_RT) { const p_set_rt *r = oa; if (!lay_same(r, t->serial, v)) break; int l = r->cview[0].min_layer; lo = MIN(lo, l); hi = MAX(hi, l); continue; }
        if (oh.op == OP_DRAW || oh.op == OP_DRAW_IDX) { if (!lay_prim_ok(oh.op == OP_DRAW ? ((const p_draw *)oa)->prim : ((const p_draw_idx *)oa)->prim)) break; continue; }
        if (!lay_op_safe(oh.op)) break;
    }
    int layers = t->d.target == NVN_TEXTURE_TARGET_CUBEMAP ? 6 : t->d.target == NVN_TEXTURE_TARGET_CUBEMAP_ARRAY ? (int)t->d.depth * 6 : (int)t->d.depth;
    if (hi <= lo || hi >= layers) return 0;
    g_lay.ser = t->serial; g_lay.v = *v; g_lay.first = lo; g_lay.count = hi - lo + 1;
    if (lay_reads_target(S.prog ? prog_get(S.prog) : nil)) return 0;   // the draw opening the pass is checked as the later ones are (draw)
    *first = lo; return hi - lo + 1;
}
static void lay_report(uint64_t f) {   // every 300 frames, when layered passes happened
    static uint64_t p[3]; uint64_t c[3] = {g_lay.passes, g_lay.merges, g_lay.splits};
    if (f % 300 || c[0] == p[0]) return;
    MLOG("layered passes up to frame %llu: %llu passes holding %llu more SetRenderTargets; %llu ended early by a draw they could not hold", (unsigned long long)f,
         (unsigned long long)(c[0] - p[0]), (unsigned long long)(c[1] - p[1]), (unsigned long long)(c[2] - p[2]));
    memcpy(p, c, sizeof p);
}
static int lay_continue(const p_set_rt *r) {   // SetRenderTargets in a layered pass: another layer of its range goes on in it
    if (!lay_same(r, g_lay.ser, &g_lay.v)) return 0;
    int l = r->cview[0].min_layer; if (l < g_lay.first || l >= g_lay.first + g_lay.count) return 0;
    R.rt = *r; g_lay.cur = l; g_lay.merges++;
    return 1;
}
// A draw in a layered pass that samples the level being rendered (any of its layers): the separate passes it replaces had only one layer attached.
// The cube filters sample the level above through a view of that level, which is fine; a view whose levels cannot be told counts as a read
static int lay_reads_target(NvProg *pr) {
    if (!pr) return 1;
    unsigned lv = g_lay.v.set_levels ? g_lay.v.base_level : 0;
    for (int st = 0; st < 5; st++) { __unsafe_unretained NvShader *sh = pr->sh[st]; if (!sh || sh->stage < 0 || sh->stage >= 5) continue;
        for (int i = 0; i < sh->rf.nb; i++) { const nvn_rbind *b = &sh->rf.b[i]; uint64_t h;
            if (b->kind == NVN_RB_IMG) h = b->reg < 32 ? S.img[sh->stage][b->reg] : 0; else if (b->kind == NVN_RB_TEX || b->kind == NVN_RB_TBUF) h = b->reg < 128 ? S.tex[sh->stage][b->reg] : 0; else continue;
            int tid = (int)(h & 0xfffff); if (!tid) continue;
            int hit = 0; pthread_mutex_lock(&g_rmu);
            if (tid < g_ntreg && g_treg[tid].ok && g_treg[tid].t.serial == g_lay.ser) {
                const view_t *v = &g_treg[tid].v; int hv = g_treg[tid].has_v;
                int lv_out = hv && v->set_levels && v->nlevels && (lv < v->base_level || lv >= (unsigned)v->base_level + v->nlevels);
                int ly_out = hv && v->set_layers && v->nlayers && (g_lay.first + g_lay.count <= v->min_layer || g_lay.first >= v->min_layer + v->nlayers);
                hit = !lv_out && !ly_out;
            }
            pthread_mutex_unlock(&g_rmu);
            if (hit) return 1; } }
    return 0;
}
static void draw(const p_draw *dw, const p_draw_idx *di) {
    if (g_render_off) return;   // SetRenderEnable(false)
    if (!S.prog) { RED_ONCE(18, "no program bound before draw"); return; }
    __unsafe_unretained NvProg *pr = prog_get(S.prog);
    if (g_nupd && !g_defer_replaying) upd_guard_draw(pr, di);   // before its render pass is opened
    if (g_ruler_truth == 0) {   // Ruler negative control (DM_NVN_RULER_NEG=<fragment key>): in the mode under test drop this shader's draws, and the ruler must report non-equivalence
        static const char *neg; static int ng = -1; if (ng < 0) { neg = getenv("DM_NVN_RULER_NEG"); ng = neg && *neg; }
        if (ng && pr) for (int st = 0; st < 5; st++) { __unsafe_unretained NvShader *sh = pr->sh[st]; if (sh && sh->stage == 1 && !strncmp(sh->key, neg, strlen(neg))) { static int once; if (!once++) MLOG("DM_NVN_RULER_NEG: measured mode drops the draws of shader %s", sh->key); return; } }
    }
    if (zskip_can_draw(pr)) {   // Zero-source skip: the output is always 0, writing 0 over 0, so this draw changes no result (see zskip_can_draw)
        g_zskip_count++; { static int once; if (!once++) MLOG("zero-source skip: first case pass %llu", g_stat_pass + 1); }
        PD("N %llu zero-source skip", g_stat_pass + 1); return; }
    g_wide_gpu = 0;
    if (di && di->itype == 0 && di->count > 0 && !g_defer_replaying && pend_hits(di->ibuf, (uint64_t)di->count))   // see wide_u8_gpu; such a draw is not deferred
        g_wide_gpu = wide_u8_gpu(di, S.restart_set && S.restart_en && S.restart_idx == 0xff);
    if (!g_defer_replaying && !g_wide_gpu) {
        if (g_defer.active && g_defer.in_p && !g_defer.at_q) { if (defer_take(dw, di)) return; }
    }
    // Draws that cannot draw anything (both faces culled, empty scissor) return before the render pass is opened: otherwise the render pass is already open and on TBDR the whole attachment is loaded and stored for nothing
    // (Mac character select page: 3 render passes are opened only because of such draws, all loaded, zero draws)
    // Diagnostic switch for measuring an upper bound DM_NVN_SKIP_FS=<fragment key>[,<fragment key>...] (none by default): drops all draws of these fragment shaders (the picture will be wrong; only used in real-device ABA to measure "how much GPU time this class of draws is worth in total")
    { static char sk[16][20]; static int nsk = -1;
      if (nsk < 0) { nsk = 0; for (const char *q = getenv("DM_NVN_SKIP_FS"); q && *q && nsk < 16; q = strchr(q, ',') ? strchr(q, ',') + 1 : q + strlen(q)) { size_t n = strcspn(q, ","); if (n > 16) n = 16; memcpy(sk[nsk], q, n); sk[nsk++][n] = 0; }
                     if (nsk) MLOG("DM_NVN_SKIP_FS: dropping the draws of %d fragment shaders (diagnostic, rendering is wrong)", nsk); }
      if (g_ub_n > 0 && pr->sh[1] && !g_defer_replaying && ub_skip(pr->sh[1]->key)) return;   // In-process alternating measurement: this phase drops this class
      if (nsk && pr->sh[1] && !g_defer_replaying) for (int i = 0; i < nsk; i++) if (!strncmp(pr->sh[1]->key, sk[i], strlen(sk[i]))) return; }
    // Similar diagnostic DM_NVN_SKIP_SMALL=<width>: drop all draws whose target width (by the attached level) is <= this value -- measures how much "dropping tiny render passes in bulk" is worth under the parallel pipeline (fixed per-pass overhead)
    { static int small = -1; if (small < 0) { const char *e = getenv("DM_NVN_SKIP_SMALL"); small = e ? atoi(e) : 0; if (small) MLOG("DM_NVN_SKIP_SMALL: dropping draws whose target width is ≤ %d (diagnostic, rendering is wrong)", small); }
      if (small > 0 && R.has_rt && !g_defer_replaying) { int k = R.rt.n && R.rt.color[0] ? 0 : R.rt.depth ? 8 : -1;
        if (k >= 0) { uint64_t s_; int lv, sl; rt_sub(&R.rt, k, &s_, &lv, &sl); const tex_t *t = k == 8 ? R.rt.depth : R.rt.color[0]; if ((int)MAX(t->d.width >> lv, 1u) <= small) return; } } }
    if (S.poly.cull == NVN_FACE_FRONT_AND_BACK) return;
    // The continued render pass may have been opened with fewer depth / stencil attachments (open modes 2 / 3 / 4): if the plane this draw needs is not attached, split before it (on reopen, attach per the new lookahead)
    if ((g_rt_merged || (g_enc && g_ren_pass == g_pass.serial)) && g_enc_mode != 0 && (((S.ds.dt || S.ds.dw) && !g_pass.hd) || (S.ds.st && !g_pass.hs))) {   // (a pass that went on past a renamed update: its lookahead did too, this is a safety net)
        static int once2; if (!once2++) MLOG("same-target continuation: a draw in the continued pass needs a depth / stencil plane that is not attached, splitting here (first case pass %llu)", g_stat_pass);
        PD("M %llu a draw in the continued pass needs an unattached depth / stencil plane, splitting here", g_stat_pass); rp_end(); }
    if (g_rt_range_active && (!rt_range_pr_ro(pr) || !S.ds.dt || S.ds.dw || S.ds.st)) rp_end();   // The external write visibility at the original encoder boundary is not removed
    if (g_lay.active && (!lay_prim_ok(dw ? dw->prim : di->prim) || lay_reads_target(pr))) { g_lay.splits++; g_lay.refuse = 1; rp_end(); }   // a draw a layered pass cannot hold: the pass ends, the next opens plain
    if (g_rt_merged && draw_samples_rt(pr)) { static int once; if (!once++) MLOG("same-target continuation: a draw in the continued pass samples an attachment, splitting here (first case pass %llu)", g_stat_pass);
        PD("M %llu a draw in the continued pass samples an attachment, splitting here", g_stat_pass); rp_end(); }
    static id<MTLFunction> fz_fn;   // Specialized fragment function for this draw of the later pass in a merged render pass (nil = use the original version)
    if (g_fz.active && g_enc && g_fz.phase == 2 && !fz_p2_draw(pr, dw, di, g_fz.lmap2, &fz_fn)) {   // Cannot be proven: end the merged render pass (the earlier pass's result is stored as usual) and reopen with the later pass's original targets
        static int once3; if (!once3++) MLOG("readable tile pass merge: a draw in the later pass is not provable, falling back to separate passes (first case pass %llu)", g_stat_pass);
        g_fz_fallback++; rp_end(); }
    if (!g_defer_replaying) fbx_prepare(pr); else if (g_fbx_nact) { g_fbx_nact = 0; args_dirty_all(); }   // a replayed deferred draw: not copied for, and it keeps the draw that replays it's picks
    if (R.has_sc && !g_enc) {
        NSUInteger tw0 = 0, th0 = 0; rt_dims(&tw0, &th0);
        long x0 = R.sc.x < 0 ? 0 : R.sc.x, y0 = R.sc.y < 0 ? 0 : R.sc.y, x1 = (long)R.sc.x + R.sc.w, y1 = (long)R.sc.y + R.sc.h;
        if (x1 > (long)tw0) x1 = tw0; if (y1 > (long)th0) y1 = th0;
        if (x1 <= x0 || y1 <= y0) return;
    }
    int defer_q_draw = !g_enc && !g_defer_replaying && g_defer_natq > 0;   // The draw that opens Q's render pass: after the render pass is opened as usual through hoist_try / fuse_try, replay P first and then draw this one
    if (!g_enc && tbdr_on()) hoist_try();   // First hoist and execute the pure-clear render passes sandwiched between this render pass and its continuation (before rp_begin_ex, not occupying this render pass)
    // The deferral decision comes after hoist_try: hoisted pure-clear render passes are skipped in the lookahead, and only then can P's same-target continuation segment be recognized
    if (!g_enc && tbdr_on() && !defer_has_in_p() && !g_defer_replaying && !g_fz.active && !g_fz_checking && g_exec_next) { defer_try(dw, di); if (g_defer_cur->active && g_defer_cur->in_p) return; }
    if (!g_enc && tbdr_on() && !g_fz_checking) fuse_try();   // Readable tile render pass merge is on by default; when the structure / same-pixel proof does not hold it still falls back to a normal render pass, and it is not re-entered during the CHECK redraw
    int need = g_enc || !tbdr_on() ? 3 : pass_ds_need(), mode = defer_q_draw ? 0 : need == 0 ? 2 : need == 2 ? 3 : need == 1 ? 4 : 0;   // 2 attach neither, 3 attach stencil only, 4 attach depth only
    int skip_d = mode != 0;
    if (!g_enc) { g_fd_dw = dw; g_fd_di = di; }
    id<MTLRenderCommandEncoder> en = rp_begin_ex(mode);
    g_fd_dw = NULL; g_fd_di = NULL;
    if (!en) return;
    if (defer_q_draw) defer_replay();
    fbx_activate();
    if (skip_d) { g_stat_ds_omit++; if (mode == 3) g_stat_s_only++; else if (mode == 4) g_stat_d_only++; }
    // The pipeline depends only on (program, render pass targets, blend / color / write mask / multisample state, vertex layout): if these did not change, reuse the previous one
    static id<MTLRenderPipelineState> cur_ps; static NvProg *cur_pr; static uint64_t cur_ps_pass;
    if (g_fz.active && !g_defer_replaying) { g_pso_lmap = g_fz.phase == 1 ? g_fz.lmap1 : g_fz.lmap2; g_pso_fsfn = g_fz.phase == 1 ? nil : fz_fn; g_pso_fz = g_fz.phase == 1 ? (pso_fz_desc){0} : g_fz_desc; g_pso_dirty = 1; }   // Readable tile merge: fetch the pipeline by the physical -> logical mapping and the specialization
    if (g_pso_dirty || pr != cur_pr || cur_ps_pass != g_pass.serial) { cur_ps = pso_get(pr, nil); cur_pr = pr; cur_ps_pass = g_pass.serial; g_pso_dirty = !cur_ps; }
    if (g_pso_lmap) { g_pso_lmap = NULL; g_pso_fsfn = nil; memset(&g_pso_fz, 0, sizeof g_pso_fz); g_pso_dirty = 1; }   // The next draw fetches again according to its own situation
    __unsafe_unretained id<MTLRenderPipelineState> ps = cur_ps;
    if (!ps) return;
    if (ps != g_enc_pso) { enc_r_pso(en, ps); g_enc_pso = ps; }
    static id<MTLDepthStencilState> cur_ds; static uint64_t cur_ds_pass;
    if (g_dss_dirty || cur_ds_pass != g_pass.serial) { cur_ds = dss_get(g_pass.hd, g_pass.hs); cur_ds_pass = g_pass.serial; g_dss_dirty = 0; }
    if (cur_ds != g_enc_dss) { enc_r_dss(en, cur_ds); g_enc_dss = cur_ds; }
    enc_r_stencil_ref(en, S.st_ref[0], S.st_ref[1]);
    if (g_lay.active && g_lay.amp != g_lay.cur - g_lay.first) { g_lay.amp = g_lay.cur - g_lay.first; enc_r_layer(en, (uint32_t)g_lay.amp); }   // this draw's layer in the layered pass
    // Viewport / scissor (clamped within the target size)
    NSUInteger tw = g_pass.tw, th = g_pass.th;
    if (S.has_vp) enc_r_viewport(en, (MTLViewport){S.vp[0][0], S.vp[0][1], S.vp[0][2], S.vp[0][3], S.dr[0], S.dr[1]});
    else enc_r_viewport(en, (MTLViewport){0, 0, tw, th, 0, 1});
    MTLScissorRect sc = {0, 0, tw, th};
    if (R.has_sc) {
        long x0 = R.sc.x < 0 ? 0 : R.sc.x, y0 = R.sc.y <= 0 ? 0 : R.sc.y, x1 = (long)R.sc.x + R.sc.w, y1 = (long)R.sc.y + R.sc.h;
        if (x1 > (long)tw) x1 = tw; if (y1 > (long)th) y1 = th;
        if (x1 <= x0 || y1 <= y0) return;
        sc = (MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)};
    }
    enc_r_scissor(en, sc);
    if (g_cnt_on > 0) { if (S.has_vp) cnt_extent(sc, S.vp[0][0], S.vp[0][1], S.vp[0][0] + S.vp[0][2], S.vp[0][1] + S.vp[0][3]); else cnt_extent(sc, 0, 0, tw, th); }
    if (S.poly.cull == NVN_FACE_FRONT_AND_BACK) return;
    { static int nocull = -1; if (nocull < 0) { nocull = getenv("DM_NVN_NOCULL") != NULL; if (nocull) MLOG("DM_NVN_NOCULL: face culling off (diagnostic, rendering is wrong)"); }   // diagnostic: does a missing draw come back without culling?
      enc_r_cull(en, nocull ? MTLCullModeNone : S.poly.cull == NVN_FACE_FRONT ? MTLCullModeFront : S.poly.cull == NVN_FACE_BACK ? MTLCullModeBack : MTLCullModeNone); }
    enc_r_winding(en, S.poly.front == NVN_FRONT_FACE_CCW ? MTLWindingCounterClockwise : MTLWindingClockwise);
    enc_r_fill(en, S.poly.mode == NVN_POLYGON_MODE_LINE ? MTLTriangleFillModeLines : MTLTriangleFillModeFill);
    if (S.poly.offset_en & 4) enc_r_depth_bias(en, S.po.units, S.po.factor, S.po.clamp); else enc_r_depth_bias(en, 0, 0, 0);
    enc_r_depth_clip(en, !S.depth_clamp);
    enc_r_blend_color(en, S.blend_color[0], S.blend_color[1], S.blend_color[2], S.blend_color[3]);
    for (int s_ = 0; s_ < 16; s_++) {
        if (!S.vbuf[s_].address) continue;
        void *mb; uint64_t mo;
        uint64_t gpu;
        if (mtl_gpu_addr(S.vbuf[s_].address, 1, &mb, &mo, &gpu)) { enc_r_vbuf(en, 16 + s_, gpu); use_rec("buf", S.vbuf[s_].address, S.vbuf[s_].size, 0, NULL); }
    }
    static id<MTLBuffer> zero; if (!zero) { zero = [g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared]; res_add(zero); }
    static uint64_t zero_gpu; if (!zero_gpu) zero_gpu = zero.gpuAddress;
    enc_r_vbuf(en, 30, zero_gpu);
    if (pr->sh[0]) encode_args(en, pr->sh[0], 0, 1);
    if (pr->sh[1]) encode_args(en, pr->sh[1], 1, 0);
    // Parameter binding captures the actual resources under the registry lock; if the version changed between the eligibility check and the binding, split and retry before any GPU draw.
    if (g_rt_range_active && (g_pass.reg_gen != g_reg_gen || g_pass.ser_gen != g_ser_gen || g_pass.range_dirty != nvn_dirty_now())) { rp_end(); draw(dw, di); return; }
    int prim = dw ? dw->prim : di->prim;
    MTLPrimitiveType mp;
    switch (prim) {
        case 0: mp = MTLPrimitiveTypePoint; break; case 1: mp = MTLPrimitiveTypeLine; break; case 3: mp = MTLPrimitiveTypeLineStrip; break;
        case 4: case 7: mp = MTLPrimitiveTypeTriangle; break; case 5: mp = MTLPrimitiveTypeTriangleStrip; break;
        default: RED_ONCE(19, "primitive type %d not implemented", prim); return;
    }
    if (g_vis_counting) {   // Occlusion query counting: a new slot for this render pass (also switch to a new slot after a report / reset)
        if (!g_enc_has_vis) RED_ONCE(34, "the pass in which occlusion query counting started has no visibility buffer attached (the first reset happened mid-pass), samples of that pass are not counted");
        else {
            if (g_vis_cur < 0 || g_vis_cur_pass != g_pass.serial) {
                if (g_vis_n >= VIS_SLOTS) RED_ONCE(35, "visibility slots exhausted");
                else { g_vis_cur = (int)g_vis_n++; g_vis_cur_pass = g_pass.serial;
                    if (g_nvs == g_vscap) { g_vscap = g_vscap ? g_vscap * 2 : 64; g_vs = realloc(g_vs, g_vscap * sizeof *g_vs); }
                    g_vs[g_nvs++] = (vis_slot){(void *)CFBridgingRetain(g_vis), (uint32_t)g_vis_cur}; }
            }
            if (g_vis_cur >= 0 && g_enc_vis != g_vis_cur + 1) { enc_r_visibility(en, MTLVisibilityResultModeCounting, (NSUInteger)g_vis_cur * 8); g_enc_vis = g_vis_cur + 1; }
        }
    }
    if (g_cnt_on > 0 || (g_cnt_on < 0 && counts_on())) count_self_sample(pr);   // after the splits above: the pass this draw lands in
    g_stat_draw++;
    if (enc_label_on() && !g_el_draws++ && pr->sh[1]) { memcpy(g_el_key, pr->sh[1]->key, 8); g_el_key[8] = 0; }
    if (passdump()) {   // Characteristics of a render pass's first draw (to judge whether the load can be omitted: full screen, no blending, writes all channels, does not depend on depth); with DM_NVN_PASSDUMP_ALL every draw is recorded
        static uint64_t last_pass = ~0ull; static int all = -1; if (all < 0) all = getenv("DM_NVN_PASSDUMP_ALL") != NULL;
        if (all) PD("d %llu bv=%d bi=%d first=%d vs=%s fs=%s vc=%d inst=%d blend=%#x b0=%#llx dt=%d dw=%d df=%d cull=%d st=%d sf=%d,%d sop=%d,%d,%d/%d,%d,%d smask=%#x,%#x/%#x,%#x sref=%#x,%#x ib=%#llx it=%d cmask=%#x", g_stat_pass, di ? di->base_vertex : 0, di ? di->base_instance : 0, dw ? dw->first : 0, pr->sh[0] ? pr->sh[0]->key : "-", pr->sh[1] ? pr->sh[1]->key : "-",
                    dw ? dw->count : di->count, dw ? (dw->instances ? dw->instances : 1) : di->instances, S.color.blend_en, (unsigned long long)*(uint64_t *)&S.blend[0], (int)S.ds.dt, (int)S.ds.dw, (int)S.ds.df, (int)S.poly.cull,
                    (int)S.ds.st, (int)S.ds.sf_f, (int)S.ds.sf_b, (int)S.ds.fail_f, (int)S.ds.zfail_f, (int)S.ds.zpass_f,
                    (int)S.ds.fail_b, (int)S.ds.zfail_b, (int)S.ds.zpass_b, S.st_vmask[0], S.st_vmask[1], S.st_wmask[0], S.st_wmask[1], S.st_ref[0], S.st_ref[1],
                    di ? (unsigned long long)di->ibuf : 0ull, di ? di->itype : 0, S.chmask.mask);
        if (all && pr->sh[0]) {   // Content fingerprint of each constant buffer of the vertex stage (to judge whether a draw is completely identical across frames: used by the shadow cache etc.); when unreadable (a write pending execution in this submit) record P
            char ub[400]; size_t o = 0; NvShader *v = pr->sh[0];
            for (int i = 0; i < v->rf.nb && o < sizeof ub - 40; i++) if (v->rf.b[i].kind == NVN_RB_CBUF && v->rf.b[i].reg < 16) {
                const p_bind_buf *u = &S.ubo[0][v->rf.b[i].reg]; void *mb; uint64_t mo; const uint8_t *base; uint64_t h = 1469598103934665603ull;
                if (!u->addr || !u->size) { o += snprintf(ub + o, sizeof ub - o, " r%d=-", v->rf.b[i].reg); continue; }
                if (pend_hits(u->addr, u->size) || !mtl_addr(u->addr, u->size, &mb, &mo) || !(base = [(__bridge id<MTLBuffer>)mb contents])) { o += snprintf(ub + o, sizeof ub - o, " r%d=P/%llu", v->rf.b[i].reg, (unsigned long long)u->size); continue; }
                uint64_t h64 = 0; for (uint64_t q = 0; q < u->size; q++) { h = (h ^ base[mo + q]) * 1099511628211ull; if (q == 63) h64 = h; }   // h64: the first 64 bytes (world matrix vec0–3 of the object buffer)
                { static uint64_t hp = ~0ull; static int hn; if (hp != g_stat_pass) { hp = g_stat_pass; hn = 0; }   // For the first 6 draws of each render pass, additionally print buffers of <= 608 bytes in hex (to compare byte by byte which fields changed across frames)
                  if (hn < 12 && u->size <= 608 && v->rf.b[i].reg == 3) { hn++; char hx[1300]; for (uint64_t q = 0; q < u->size; q++) snprintf(hx + 2 * q, 3, "%02x", base[mo + q]); PD("x %llu r%d %s", g_stat_pass, v->rf.b[i].reg, hx); } }
                o += snprintf(ub + o, sizeof ub - o, " r%d=%016llx/%llu/%016llx", v->rf.b[i].reg, (unsigned long long)h, (unsigned long long)u->size, (unsigned long long)h64); }
            PD("u %llu%s", g_stat_pass, ub); }
        if (all) { char vb[512]; size_t o = 0; o += snprintf(vb + o, sizeof vb - o, "nattr=%d", S.nattr);
            for (int i = 0; i < S.nattr && i < 6; i++) { int st = S.attr[i].stream;
                o += snprintf(vb + o, sizeof vb - o, " a%d{fmt=%#x off=%d s=%d stride=%u div=%u vb=%#llx/%llu}", i, S.attr[i].fmt, S.attr[i].offset, st,
                              st < 16 ? S.stream[st].stride : 0, st < 16 ? S.stream[st].divisor : 0, st < 16 ? (unsigned long long)S.vbuf[st].address : 0ull, st < 16 ? (unsigned long long)S.vbuf[st].size : 0ull); }
            PD("v %llu %s", g_stat_pass, vb);
            if (S.nattr > 0 && S.attr[0].stream < 16 && S.vbuf[S.attr[0].stream].address && S.attr[0].fmt == 0x29) {   // a0 as RGBA16F: the first 4 vertices
                const uint16_t *hv = (const uint16_t *)(uintptr_t)(S.vbuf[S.attr[0].stream].address + S.attr[0].offset); uint32_t st = S.stream[S.attr[0].stream].stride; char hx[300]; size_t ho = 0;
                for (int k = 0; k < 4 && (uint64_t)k * st + 8 <= S.vbuf[S.attr[0].stream].size; k++) { const uint16_t *e = (const uint16_t *)((const uint8_t *)hv + (size_t)k * st);
                    ho += snprintf(hx + ho, sizeof hx - ho, " (%g %g %g %g)", (double)*(const __fp16 *)&e[0], (double)*(const __fp16 *)&e[1], (double)*(const __fp16 *)&e[2], (double)*(const __fp16 *)&e[3]); }
                PD("v %llu a0 data%s", g_stat_pass, hx); } }
        if (last_pass != g_stat_pass) {
            last_pass = g_stat_pass;
            PD("D %llu prim=%d vc=%d inst=%d blend=%#x wm=%#x dt=%d dw=%d df=%d st=%d sc=%lu,%lu,%lu,%lu tgt=%lux%lu vp=%.0f,%.0f,%.0f,%.0f cull=%d front=%d dr=%.3g,%.3g it=%d", g_stat_pass, prim,
               dw ? dw->count : di->count, dw ? (dw->instances ? dw->instances : 1) : di->instances, S.color.blend_en, S.chmask.mask, (int)S.ds.dt, (int)S.ds.dw, (int)S.ds.df, (int)S.ds.st,
               (unsigned long)sc.x, (unsigned long)sc.y, (unsigned long)sc.width, (unsigned long)sc.height, (unsigned long)tw, (unsigned long)th,
               S.has_vp ? S.vp[0][0] : 0, S.has_vp ? S.vp[0][1] : 0, S.has_vp ? S.vp[0][2] : (float)tw, S.has_vp ? S.vp[0][3] : (float)th, (int)S.poly.cull, (int)S.poly.front, S.dr[0], S.dr[1], di ? di->itype : -1);
        }
    }
    if (rt_range_on() && !rt_range_pr_ro(pr)) g_pass.range_external=1;
    rt_range_note_depth();
    udc_note_draw(pr);
    // A draw with 0 primitives (the game does send count=0) draws no pixels, so skip encoding; Metal requires the count to be non-zero, otherwise the validation layer aborts on the spot (measured on the camp / wilderness / combat pages)
    if (dw && prim == 7) {   // Quads: shared indices 0,1,2,0,2,3
        if (!g_quad_ib) {
            uint32_t n = 65536; uint32_t *ix = malloc(n * 6 * 4);
            for (uint32_t q = 0; q < n; q++) { uint32_t b = q * 4; uint32_t v[6] = {b, b + 1, b + 2, b, b + 2, b + 3}; memcpy(ix + q * 6, v, 24); }
            g_quad_ib = [g_dev newBufferWithBytes:ix length:n * 24 options:MTLResourceStorageModeShared]; g_quad_gpu = g_quad_ib.gpuAddress; res_add(g_quad_ib); free(ix);
        }
        if (dw->count >= 4) enc_r_draw_indexed(en, mp, (dw->count / 4) * 6, MTLIndexTypeUInt32, g_quad_gpu, g_quad_ib.length, dw->instances ? dw->instances : 1, dw->first, dw->base_instance);
    } else if (dw) {
        if (dw->count) enc_r_draw_instanced(en, mp, dw->first, dw->count, dw->instances ? dw->instances : 1, dw->base_instance);
    } else {
        if (prim == 7) { RED_ONCE(20, "indexed quads not implemented"); return; }
        // Primitive restart: NVN restarts any primitive where an index equals the restart index exactly (SDK: an 8-bit index never matches one outside
        // 0..255); Metal restarts only strips, only at the all-ones index of the index type, always. Until the game sets it nothing changes (its default
        // state is not documented). Strips whose restart index is not all-ones get their indices rewritten in this submission's arena; what cannot be
        // expressed (a list with a restart, a strip with restart off holding all-ones) is reported (t_restart)
        int strip = mp == MTLPrimitiveTypeLineStrip || mp == MTLPrimitiveTypeTriangleStrip, rs = S.restart_set && S.restart_en;
        if (di->itype == 0) {   // 8-bit indices (Tears of the Kingdom draws most quads with them): Metal has only 16 / 32-bit index buffers, so they are widened into this submission's arena
            if (!di->count) return;
            const uint8_t *src8 = (const uint8_t *)(uintptr_t)di->ibuf; void *mb; uint64_t mo;
            if (!mtl_addr(di->ibuf, (uint64_t)di->count, &mb, &mo)) { RED_ONCE(21, "8-bit index buffer is not in a memory pool"); return; }
            if (g_wide_gpu) {   // widened on the GPU before the pass (wide_u8_gpu)
                use_rec("buf", di->ibuf, (uint64_t)di->count, 0, NULL);
                enc_r_draw_indexed(en, mp, di->count, MTLIndexTypeUInt16, g_wide_gpu, (NSUInteger)di->count * 2, di->instances ? di->instances : 1, di->base_vertex, di->base_instance);
                g_wide_gpu = 0;
                if (g_rt_range_pending) { PD("j rt_level_range pass=%llu vc=%u", g_stat_pass, (unsigned)di->count); g_rt_range_pending = 0; }
                return;
            }
            if (pend_hits(di->ibuf, (uint64_t)di->count)) RED_ONCE(83, "8-bit indices written by the GPU earlier in this submission are widened from memory (first case %#llx)", (unsigned long long)di->ibuf);
            use_rec("buf", di->ibuf, (uint64_t)di->count, 0, NULL);
            id<MTLBuffer> ab; size_t ao = arena_alloc((size_t)di->count * 2, &ab); uint16_t *d16 = (uint16_t *)((uint8_t *)ab.contents + ao);
            int r8 = rs && S.restart_idx == 0xff, hit = 0;
            for (int k = 0; k < di->count; k++) { int r = r8 && src8[k] == 0xff; hit |= r; d16[k] = r ? 0xffff : src8[k]; }
            if (hit && !strip) RED_ONCE(84, "primitive restart in a list (index %#x): Metal restarts only strips, drawn without the restart", S.restart_idx);
            enc_r_draw_indexed(en, mp, di->count, MTLIndexTypeUInt16, g_cur_arena->gpu + ao, (NSUInteger)di->count * 2, di->instances ? di->instances : 1, di->base_vertex, di->base_instance);
        } else {
            void *mb; uint64_t mo;
            uint64_t gpu;
            if (!mtl_gpu_addr(di->ibuf, 1, &mb, &mo, &gpu)) { RED_ONCE(22, "index buffer is not in a memory pool"); return; }
            int w = di->itype == 1 ? 2 : 4; uint32_t ones = w == 2 ? 0xffffu : 0xffffffffu;
            use_rec("buf", di->ibuf, (uint64_t)di->count * (uint64_t)w, 0, NULL);
            NSUInteger len = ((__bridge id<MTLBuffer>)mb).length - mo;
            if (S.restart_set && di->count && (rs ? S.restart_idx != ones : strip && w == 2)) {   // NVN and Metal would restart at different indices
                const uint8_t *src = (const uint8_t *)(uintptr_t)di->ibuf;
                if (pend_hits(di->ibuf, (uint64_t)di->count * (uint64_t)w)) RED_ONCE(85, "indices written by the GPU earlier in this submission are checked for primitive restart in memory (first case %#llx)", (unsigned long long)di->ibuf);
                if (!rs) {   // restart off: an all-ones 16-bit index is a vertex on NVN, a restart in a Metal strip
                    for (int k = 0; k < di->count; k++) { uint16_t v; memcpy(&v, src + 2 * k, 2); if (v == 0xffff) { RED_ONCE(86, "16-bit index 0xffff in a strip with primitive restart off: Metal restarts there"); break; } }
                } else if (!strip) {
                    for (int k = 0; k < di->count; k++) { uint32_t v = 0; memcpy(&v, src + w * k, w); if (v == S.restart_idx) { RED_ONCE(84, "primitive restart in a list (index %#x): Metal restarts only strips, drawn without the restart", S.restart_idx); break; } }
                } else {
                    id<MTLBuffer> ab; size_t ao = arena_alloc((size_t)di->count * w, &ab); uint8_t *dst = (uint8_t *)ab.contents + ao;
                    for (int k = 0; k < di->count; k++) { uint32_t v = 0; memcpy(&v, src + w * k, w); if (v == S.restart_idx) v = ones; else if (v == ones) RED_ONCE(86, "all-ones index in a strip whose restart index is %#x: Metal restarts there", S.restart_idx); memcpy(dst + w * k, &v, w); }
                    gpu = g_cur_arena->gpu + ao; len = (NSUInteger)di->count * w;
                }
            }
            if (di->count) enc_r_draw_indexed(en, mp, di->count, w == 2 ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32, gpu, len,
                    di->instances ? di->instances : 1, di->base_vertex, di->base_instance);
        }
    }
    if (g_rt_range_pending) { PD("j rt_level_range pass=%llu vc=%u", g_stat_pass, (unsigned)(dw ? dw->count : di->count)); g_rt_range_pending=0; }
}
static nvn_hmap g_cps = {.klen = sizeof(void *)};
static void warm_claim(void) {
    if (!atomic_exchange_explicit(&g_warm_ready, 0, memory_order_acq_rel)) return;
    os_unfair_lock_lock(&g_warm_lock);
    NSArray<WarmItem *> *items = [g_warm_items copy];
    [g_warm_items removeAllObjects];
    os_unfair_lock_unlock(&g_warm_lock);
    for (WarmItem *item in items) {
        if (item->kind == 0) {
            if (!g_shcache) g_shcache = [NSMutableDictionary dictionary];
            if (!g_shcache[item->key]) { g_shcache[item->key] = item->shader; g_warm_claim_shaders++; }
        } else if (item->kind == 1) {
            if (!g_shcache) g_shcache = [NSMutableDictionary dictionary];
            NvShader *vs = g_shcache[item->vs_key], *fs = item->fs_key.length ? g_shcache[item->fs_key] : nil;
            if (!vs) { vs = item->vs; g_shcache[item->vs_key] = vs; }
            if (item->fs_key.length && !fs) { fs = item->fs; g_shcache[item->fs_key] = fs; }
            item->pso.vs = (__bridge void *)vs; item->pso.fs = (__bridge void *)fs;
            if (!hm_get_id(&g_pso, &item->pso)) { hm_put_id(&g_pso, &item->pso, item->object); g_warm_claim_rps++; }
        } else {
            NvShader *cs = g_shcache[item->key];
            if (!cs) { cs = item->shader; if (!g_shcache) g_shcache = [NSMutableDictionary dictionary]; g_shcache[item->key] = cs; }
            const void *key = (__bridge const void *)cs;
            if (!hm_get_id(&g_cps, &key)) { hm_put_id(&g_cps, &key, item->object); g_warm_claim_cps++; }
        }
    }
}
static void dispatch(const p_dispatch *dp) {
    zskip_clear();
    if (g_nupd) upd_flush();   // compute reads uniforms from memory: renamed updates are written first
    if (!S.prog) { RED_ONCE(27, "no program bound before dispatch"); return; }
    NvShader *cs = prog_get(S.prog)->sh[5];
    if (!cs) { RED_ONCE(28, "dispatched program has no compute shader (or it is not mapped)"); return; }
    const void *k = (__bridge const void *)cs;
    id<MTLComputePipelineState> ps = hm_get_id(&g_cps, &k);
    if (!ps) {
        NSError *e = nil; uint64_t bt = bp_now(); ps = [g_dev newComputePipelineStateWithFunction:cs->fn error:&e];
        g_bp_pso_n++; g_bp_pso_ns += bp_now() - bt;
        if (!ps) { MLOG("[red] failed to create compute pipeline: %s", e.localizedDescription.UTF8String); return; }
        pso_record("C\t%s\n", cs->key);
        if (cs->key[0]) pso_user_record("C\t%s\n", cs->key);
        hm_put_id(&g_cps, &k, ps);
    }
    const uint16_t *tg = cs->rf.tg;
    if (!tg[0]) { RED_ONCE(29, "compute shader lacks threadgroup size reflection"); return; }
#if DM_NVN_M3
    rp_end(); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    chunk_maybe_split();
    args_dirty_all(); CENC ce = enc_c_begin(pg_compute_desc());
#else
    // Back-to-back dispatches share one compute encoder (MacNativeGames, MIT): on Metal 4 the copy encoder g_blit is a compute encoder, kept open across
    // copies and closed wherever another encoder starts or the command buffer is committed; a dispatch uses it too, after a barrier that orders the blit
    // and dispatch stages with device visibility, as the end / start barriers of two encoders did (blit()). The argument table is set for every dispatch
    // (copies use none). Each dispatch opened and ended an encoder of its own (Tears of the Kingdom: about 24 a world frame, 13 right after another)
    rp_end(); int open = g_blit != nil;
    CENC ce = blit(); [ce setArgumentTable:g_ct]; args_dirty_all(); g_disp_n++; g_disp_shared += open;
#endif
    enc_c_pso(ce, ps);
    g_dispatch_grid[0] = (uint32_t)dp->x; g_dispatch_grid[1] = (uint32_t)dp->y; g_dispatch_grid[2] = (uint32_t)dp->z;   // c0 + 0x200 (drv_fill)
    encode_args(ce, cs, 5, 0);
#if !DM_NVN_M3
    int pg_slot = pg_dispatch_begin(ce);
#endif
    enc_c_dispatch(ce, MTLSizeMake(dp->x, dp->y, dp->z), MTLSizeMake(tg[0], tg[1], tg[2]));
#if DM_NVN_M3
    enc_c_end(ce);
#else
    pg_dispatch_end(ce, pg_slot);
#endif
}
// GPU: texture -> buffer (row / image strides from SetCopyRowStride / SetCopyImageStride, 0 = tightly packed; nvn_copy_pitch.h)
static void copy_t2b(const p_copy_b2t *c) {
    if (c->tex) xv_check(c->tex->serial, c->has_view && c->view.set_levels ? c->view.base_level : 0, c->has_view && c->view.set_layers ? c->view.min_layer : 0, "texture-to-buffer copy");
    id<MTLTexture> t = tex_mtl(c->tex);
    if (!t) return;
    int bw, bh, bpb = nvn_fmt_bpb(c->tex->d.format, &bw, &bh);
    unsigned level = c->has_view && c->view.set_levels ? c->view.base_level : 0, layer0 = c->has_view && c->view.set_layers ? c->view.min_layer : 0;
    size_t row, img, extent;
    if (!nvn_copy_pitch(c->r.width, c->r.height, c->r.depth, bw, bh, bpb, S.copy_stride, S.copy_image_stride, &row, &img, &extent)) {
        RED_ONCE(67, "texture→buffer copy with invalid strides (row %lld, image %lld, %dx%dx%d)", (long long)S.copy_stride, (long long)S.copy_image_stride, c->r.width, c->r.height, c->r.depth); return; }
    int is3d = c->tex->d.target == 2, nz = c->r.depth ? c->r.depth : 1;
    void *mb; uint64_t mo;
    if (!mtl_addr(c->src, extent, &mb, &mo)) { RED_ONCE(31, "texture→buffer copy destination is not in a memory pool"); return; }
    us_drop(c->src, extent);
    BENC b = blit();
    if (is3d)
        enc_b_copy_texture_buffer(b, t, 0, level, MTLOriginMake(c->r.xoffset, c->r.yoffset, c->r.zoffset), MTLSizeMake(c->r.width, c->r.height, nz), (__bridge id<MTLBuffer>)mb, mo, row, img);
    else
        for (int z = 0; z < nz; z++)
            enc_b_copy_texture_buffer(b, t, layer0 + c->r.zoffset + z, level, MTLOriginMake(c->r.xoffset, c->r.yoffset, 0), MTLSizeMake(c->r.width, c->r.height, 1), (__bridge id<MTLBuffer>)mb, mo + z * img, row, img);
}
// CPU texture read (ReadTexels): for packaged textures the pool memory is the ground truth, de-layout and read directly; the rest are read back from the MTLTexture by blit (the caller has already waited for the GPU per NVN rules)
void mtl_read_texels(const tex_t *t, unsigned level, unsigned layer0, const NVNcopyRegion *r, uint8_t *dst, size_t row, size_t img) { @autoreleasepool {
    xv_check(t->serial, level, layer0, "CPU readback");
    PD("U cpu_read ser=%llu lv%u sl%u xyz=%d,%d,%d size=%d,%d,%d dst=%p row=%lu img=%lu", t->serial, level, layer0, r->xoffset, r->yoffset, r->zoffset, r->width, r->height, r->depth, dst, (unsigned long)row, (unsigned long)img);
    int bw, bh, bpb = nvn_fmt_bpb(t->d.format, &bw, &bh);
    size_t wb = (size_t)((r->width + bw - 1) / bw) * bpb, hb = (r->height + bh - 1) / bh, x0 = (size_t)(r->xoffset / bw) * bpb, y0 = r->yoffset / bh;
    int nz = r->depth ? r->depth : 1, is3d = t->d.target == 2;
    if (tex_membacked(t)) {   // packaged or CPU-filled: the pool memory is the content
        uint32_t lw = MAX(t->d.width >> level, 1u), lh = MAX(t->d.height >> level, 1u), lz = is3d ? MAX(t->d.depth >> level, 1u) : 1;
        size_t lp = (size_t)((lw + bw - 1) / bw) * bpb, lr = (lh + bh - 1) / bh;
        uint8_t *lin = malloc(lp * lr * lz);
        for (int z = 0; z < nz; z++) {
            unsigned layer = is3d ? 0 : layer0 + r->zoffset + z;
            if ((is3d && z == 0) || !is3d) if (nvn_deswizzle(&t->d, level, layer, t->mem, lin, lp)) { RED_ONCE(32, "ReadTexels deswizzle failed"); free(lin); return; }
            const uint8_t *src = lin + (is3d ? (size_t)(r->zoffset + z) * lp * lr : 0);
            for (size_t y = 0; y < hb; y++) memcpy(dst + z * img + y * row, src + (y0 + y) * lp + x0, wb);
        }
        free(lin);
        return;
    }
    id<MTLTexture> mt = tex_mtl(t);
    if (!mt) { memset(dst, 0, img * nz); return; }
    mtl_finish_gpu();
    id<MTLBuffer> buf = [g_dev newBufferWithLength:wb * hb * nz options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> b = enc_b_begin(cb);
    for (int z = 0; z < nz; z++)
        [b copyFromTexture:mt sourceSlice:is3d ? 0 : layer0 + r->zoffset + z sourceLevel:level sourceOrigin:MTLOriginMake(r->xoffset, r->yoffset, is3d ? r->zoffset + z : 0)
                sourceSize:MTLSizeMake(r->width, r->height, 1) toBuffer:buf destinationOffset:z * wb * hb destinationBytesPerRow:wb destinationBytesPerImage:wb * hb];
    enc_b_end(b); [cb commit]; [cb waitUntilCompleted];
    for (int z = 0; z < nz; z++) for (size_t y = 0; y < hb; y++) memcpy(dst + z * img + y * row, (uint8_t *)buf.contents + z * wb * hb + y * wb, wb);
} }
// CPU texture write (WriteTexels): for packaged textures the pool memory is the ground truth -- deswizzle this level / layer, patch the region, swizzle back; the pool write triggers a re-upload through dirty-page tracking;
// the rest are blitted into the MTLTexture through a shared staging buffer, committed synchronously (later submissions are queued after it on the same queue)
void mtl_write_texels(const tex_t *t, unsigned level, unsigned layer0, const NVNcopyRegion *r, const uint8_t *src, size_t row, size_t img) { @autoreleasepool {
    int bw, bh, bpb = nvn_fmt_bpb(t->d.format, &bw, &bh);
    if (!bpb) { RED_ONCE(64, "WriteTexels unknown format %#x", t->d.format); return; }
    size_t wb = (size_t)((r->width + bw - 1) / bw) * bpb, hb = (r->height + bh - 1) / bh, x0 = (size_t)(r->xoffset / bw) * bpb, y0 = r->yoffset / bh;
    int nz = r->depth ? r->depth : 1, is3d = t->d.target == 2;
    if (tex_membacked(t)) {   // packaged or CPU-filled: patch the pool memory, dirty-page tracking re-uploads it
        uint32_t lw = MAX(t->d.width >> level, 1u), lh = MAX(t->d.height >> level, 1u), lz = is3d ? MAX(t->d.depth >> level, 1u) : 1;
        size_t lp = (size_t)((lw + bw - 1) / bw) * bpb, lr = (lh + bh - 1) / bh;
        uint8_t *lin = malloc(lp * lr * lz);
        for (int z = 0; z < nz; z++) {
            unsigned layer = is3d ? 0 : layer0 + r->zoffset + z;
            if ((is3d && z == 0) || !is3d) if (nvn_deswizzle(&t->d, level, layer, t->mem, lin, lp)) { RED_ONCE(65, "WriteTexels deswizzle failed format %#x target %d", t->d.format, t->d.target); free(lin); return; }
            uint8_t *dst = lin + (is3d ? (size_t)(r->zoffset + z) * lp * lr : 0);
            for (size_t y = 0; y < hb; y++) memcpy(dst + (y0 + y) * lp + x0, src + z * img + y * row, wb);
            if ((is3d && z == nz - 1) || !is3d) if (nvn_swizzle(&t->d, level, layer, lin, lp, t->mem)) { RED_ONCE(65, "WriteTexels swizzle failed format %#x target %d", t->d.format, t->d.target); free(lin); return; }
        }
        free(lin);
        return;
    }
    uint32_t upf; int ubpp;
    if (bc_unpack(t->d.format, &upf, &ubpp)) { RED_ONCE(66, "WriteTexels: compressed format %#x on a device without BC not implemented", t->d.format); return; }
    id<MTLTexture> mt = tex_mtl(t);
    if (!mt) return;
    id<MTLBuffer> buf = [g_dev newBufferWithLength:wb * hb * nz options:MTLResourceStorageModeShared];
    for (int z = 0; z < nz; z++) for (size_t y = 0; y < hb; y++) memcpy((uint8_t *)buf.contents + z * wb * hb + y * wb, src + z * img + y * row, wb);
    id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> b = enc_b_begin(cb);
    for (int z = 0; z < nz; z++)
        [b copyFromBuffer:buf sourceOffset:z * wb * hb sourceBytesPerRow:wb sourceBytesPerImage:wb * hb sourceSize:MTLSizeMake(r->width, r->height, 1)
                toTexture:mt destinationSlice:is3d ? 0 : layer0 + r->zoffset + z destinationLevel:level destinationOrigin:MTLOriginMake(r->xoffset, r->yoffset, is3d ? r->zoffset + z : 0)];
    enc_b_end(b); [cb commit]; [cb waitUntilCompleted];
} }
// Last buffer→texture copy handed to the driver, for the crash report (crash.c calls mtl_crash_note; plain values only, written before each encode):
// a crash inside the driver's copy encoder was seen a few times in repeated scene loads on the Mac, with a garbage or near-null address
static struct { uint64_t seq, tid, ser, src, off, row, img, buf_len; const void *buf, *tex; unsigned w, h, d, arr, mips, pf, type, storage, usage, fmt, target, cw, ch, cz, x, y, slice, level, in_pools; } g_last_b2t;
void mtl_crash_note(void) {
    if (!g_last_b2t.seq) return;
    fprintf(stderr, "[dm] last buffer→texture copy #%llu (thread %llu): texture %p ser=%llu %ux%ux%u array %u mips %u Metal format %u type %u storage %u usage %#x (NVN format %#x target %u); "
            "buffer %p length %llu offset %llu (guest %#llx, %s the pool table); row %llu image %llu; region %ux%ux%u at %u,%u slice %u level %u\n",
            (unsigned long long)g_last_b2t.seq, (unsigned long long)g_last_b2t.tid, g_last_b2t.tex, (unsigned long long)g_last_b2t.ser, g_last_b2t.w, g_last_b2t.h, g_last_b2t.d, g_last_b2t.arr, g_last_b2t.mips,
            g_last_b2t.pf, g_last_b2t.type, g_last_b2t.storage, g_last_b2t.usage, g_last_b2t.fmt, g_last_b2t.target, g_last_b2t.buf, (unsigned long long)g_last_b2t.buf_len, (unsigned long long)g_last_b2t.off,
            (unsigned long long)g_last_b2t.src, g_last_b2t.in_pools ? "in" : "NOT in", (unsigned long long)g_last_b2t.row, (unsigned long long)g_last_b2t.img, g_last_b2t.cw, g_last_b2t.ch, g_last_b2t.cz,
            g_last_b2t.x, g_last_b2t.y, g_last_b2t.slice, g_last_b2t.level);
}
static int pool_buf_listed(const void *buf) { int hit = 0; pthread_mutex_lock(&g_mu); for (int i = 0; i < g_npool && !hit; i++) hit = (__bridge const void *)g_pools[i].buf == buf; pthread_mutex_unlock(&g_mu); return hit; }
static void b2t_note(const p_copy_b2t *c, id<MTLTexture> t, id<MTLBuffer> b, uint64_t off, size_t row, size_t img, unsigned cz, unsigned slice, unsigned level) {
    static uint64_t seq; uint64_t tid; pthread_threadid_np(NULL, &tid);
    int listed = pool_buf_listed((__bridge const void *)b);
    if (!listed) RED_ONCE(90, "buffer→texture copy: the source buffer %p is no longer in the memory pool table at encode time (texture ser=%llu)", (__bridge const void *)b, c->tex->serial);
    g_last_b2t = (typeof(g_last_b2t)){++seq, tid, c->tex->serial, c->src, off, row, img, (uint64_t)b.length, (__bridge const void *)b, (__bridge const void *)t,
        (unsigned)t.width, (unsigned)t.height, (unsigned)t.depth, (unsigned)t.arrayLength, (unsigned)t.mipmapLevelCount, (unsigned)t.pixelFormat, (unsigned)t.textureType, (unsigned)t.storageMode, (unsigned)t.usage,
        c->tex->d.format, (unsigned)c->tex->d.target, c->r.width, c->r.height, cz, (unsigned)c->r.xoffset, (unsigned)c->r.yoffset, slice, level, (unsigned)listed};
}
static void copy_b2t(const p_copy_b2t *c) {
    if (c->tex) zskip_del(c->tex->serial);
    tex_gpu_write(c->tex);
    id<MTLTexture> t = tex_mtl(c->tex);
    PD("C ser=%llu", c->tex->serial);
    if (!t) return;
    int bw, bh, bpb = nvn_fmt_bpb(c->tex->d.format, &bw, &bh);
    unsigned level = c->has_view && c->view.set_levels ? c->view.base_level : 0, layer0 = c->has_view && c->view.set_layers ? c->view.min_layer : 0;
    size_t row, img, extent;
    if (!nvn_copy_pitch(c->r.width, c->r.height, c->r.depth, bw, bh, bpb, S.copy_stride, S.copy_image_stride, &row, &img, &extent)) {
        RED_ONCE(68, "buffer→texture copy with invalid strides (row %lld, image %lld, %dx%dx%d)", (long long)S.copy_stride, (long long)S.copy_image_stride, c->r.width, c->r.height, c->r.depth); return; }
    int is3d = c->tex->d.target == 2, nz = c->r.depth ? c->r.depth : 1;
    void *mb; uint64_t mo;
    if (!mtl_addr(c->src, extent, &mb, &mo)) { RED_ONCE(23, "buffer→texture copy source is not in a memory pool"); return; }
    uint32_t upf; int ubpp;
    if (bc_unpack(c->tex->d.format, &upf, &ubpp)) {   // No BC: the compressed blocks in the source are decompressed on the CPU into a temporary buffer, then copied pixel-wise into the decompressed-format texture
        const uint8_t *src = [(__bridge id<MTLBuffer>)mb contents];
        if (!src) { RED_ONCE(46, "no-BC decompression: the source buffer of the buffer→texture copy is not CPU-readable"); return; }
        size_t up = (size_t)c->r.width * ubpp, uimg = up * c->r.height;
        id<MTLBuffer> tb = [g_dev newBufferWithLength:uimg * nz ?: 16 options:MTLResourceStorageModeShared];
        for (int z = 0; z < nz; z++) nvn_bc_decode(c->tex->d.format, src + mo + z * img, row, c->r.width, c->r.height, (uint8_t *)tb.contents + z * uimg, up);
        res_add(tb);
        BENC b = blit();
        if (is3d) enc_b_copy_buffer_texture(b, tb, 0, up, uimg, MTLSizeMake(c->r.width, c->r.height, nz), t, 0, level, MTLOriginMake(c->r.xoffset, c->r.yoffset, c->r.zoffset));
        else for (int z = 0; z < nz; z++) enc_b_copy_buffer_texture(b, tb, z * uimg, up, uimg, MTLSizeMake(c->r.width, c->r.height, 1), t, layer0 + c->r.zoffset + z, level, MTLOriginMake(c->r.xoffset, c->r.yoffset, 0));
        defer_obj_release(tb);   // Release after this submit has finished running (and remove from residency)
        return;
    }
    BENC b = blit();
    if (is3d) {
        b2t_note(c, t, (__bridge id<MTLBuffer>)mb, mo, row, img, (unsigned)nz, 0, level);
        enc_b_copy_buffer_texture(b, (__bridge id<MTLBuffer>)mb, mo, row, img, MTLSizeMake(c->r.width, c->r.height, nz), t, 0, level, MTLOriginMake(c->r.xoffset, c->r.yoffset, c->r.zoffset));
    } else
        for (int z = 0; z < nz; z++) {
            b2t_note(c, t, (__bridge id<MTLBuffer>)mb, mo + z * img, row, img, 1, layer0 + c->r.zoffset + z, level);
            enc_b_copy_buffer_texture(b, (__bridge id<MTLBuffer>)mb, mo + z * img, row, img, MTLSizeMake(c->r.width, c->r.height, 1), t, layer0 + c->r.zoffset + z, level, MTLOriginMake(c->r.xoffset, c->r.yoffset, 0));
        }
}

// No BC + Legacy Device Pack: the game copies textures from files (already ASTC 4x4) whole into a BC3 texture array it creates itself (created as RGBA8 when there is no BC). On Switch the two formats have the same block size and
// the copy moves raw blocks; here it is changed to a compute kernel that decodes pixel by pixel and writes them in, with sRGB sources first read out as linear values and then encoded back to sRGB values, so the result = the values read in the destination format after moving the blocks as-is
static const char k_a2u_msl[] =
"#include <metal_stdlib>\nusing namespace metal;\n"
"static float3 enc(float3 c) { return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308); }\n"
"kernel void a2u(texture2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], constant uint4 *p [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
"  if (g.x >= p[1].x || g.y >= p[1].y) return; float4 v = src.read(g + p[0].xy); if (p[1].z) v.rgb = enc(v.rgb); dst.write(v, g + p[0].zw); }\n";
static int copy_t2t_astc(id<MTLTexture> s, id<MTLTexture> d, unsigned sl, unsigned ss, unsigned dl, unsigned ds, int sx, int sy, int dx, int dy, int w, int h) {
    static int failed; static id<MTLComputePipelineState> ps;
#if !DM_NVN_M3
    static id<MTL4ArgumentTable> at;
#endif
    if (failed) return 0;
    if (!ps) { NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(k_a2u_msl) options:nil error:&e]; id<MTLFunction> f = lib ? [lib newFunctionWithName:@"a2u"] : nil;
        ps = f ? [g_dev newComputePipelineStateWithFunction:f error:&e] : nil;
#if !DM_NVN_M3
        MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxTextureBindCount = 2; ad.maxBufferBindCount = 1; at = [g_dev newArgumentTableWithDescriptor:ad error:&e];
#endif
        if (!ps M4_ONLY(|| !at)) { failed = 1; MLOG("[red] no BC: cannot create the compute pipeline for the ASTC → decompressed format copy %s", e.localizedDescription.UTF8String); return 0; } }
    MTLTextureType tt = MTLTextureType2D;
    id<MTLTexture> sv = [s newTextureViewWithPixelFormat:s.pixelFormat textureType:tt levels:NSMakeRange(sl, 1) slices:NSMakeRange(ss, 1)];
    id<MTLTexture> dv = [d newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:tt levels:NSMakeRange(dl, 1) slices:NSMakeRange(ds, 1)];
    id<MTLBuffer> pb = [g_dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
    if (!sv || !dv || !pb) { RED_ONCE(47, "no BC: ASTC → decompressed format copy cannot create view / parameter block"); return 0; }
    uint32_t *p = pb.contents; p[0] = sx; p[1] = sy; p[2] = dx; p[3] = dy; p[4] = w; p[5] = h; p[6] = s.pixelFormat == MTLPixelFormatASTC_4x4_sRGB; p[7] = 0;
    res_add(pb);
    rp_end(); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    CENC ce = (CENC)enc_c_begin(NULL);
#if DM_NVN_M3
    [ce setTexture:sv atIndex:0]; [ce setTexture:dv atIndex:1]; [ce setBuffer:pb offset:0 atIndex:0];
#else
    [ce setArgumentTable:at];
    [at setTexture:sv.gpuResourceID atIndex:0]; [at setTexture:dv.gpuResourceID atIndex:1]; [at setAddress:pb.gpuAddress atIndex:0];
#endif
    enc_c_pso(ce, ps); enc_c_dispatch(ce, MTLSizeMake((w + 7) / 8, (h + 7) / 8, 1), MTLSizeMake(8, 8, 1)); enc_c_end(ce);
    args_dirty_all();
    defer_obj_unref(sv); defer_obj_unref(dv); defer_obj_release(pb);   // Release after this submit has finished running (views are not made resident separately; the parameter block is removed from residency)
    return 1;
}
// GPU: texture -> texture (previously mislisted as a no-op, 3 times per frame on the character select page). Same size, not mirrored, same format -> blit layer by layer; the other semantics (scaling with filtering, mirroring, format change) cannot be expressed by blit: report a failure, to be implemented
static void copy_t2t(const p_copy_t2t *c) {
    if (c->src) xv_check(c->src->serial, c->has_sv && c->sv.set_levels ? c->sv.base_level : 0, c->has_sv && c->sv.set_layers ? c->sv.min_layer : 0, "texture copy source");
    rp_flush();   // Land the pending pure-clear render pass first (zero-source candidates only enter the set when the render pass ends); the blit() below would end the render pass anyway
    if (c->dst) zskip_del(c->dst->serial);
    if (c->src && c->dst && c->sr.xoffset == 0 && c->sr.yoffset == 0 && c->dr.xoffset == 0 && c->dr.yoffset == 0
        && c->sr.width == (int)c->src->d.width && c->sr.height == (int)c->src->d.height && c->dr.width == (int)c->dst->d.width && c->dr.height == (int)c->dst->d.height) {
        int sl = c->has_sv && c->sv.set_levels ? c->sv.base_level : 0, dl = c->has_dv && c->dv.set_levels ? c->dv.base_level : 0;
        int ss = c->has_sv && c->sv.set_layers ? c->sv.min_layer : 0, ds = c->has_dv && c->dv.set_layers ? c->dv.min_layer : 0;
        if (zskip_has(c->src->serial, sl, ss)) zskip_add(c->dst->serial, dl, ds);
    }
    tex_gpu_write(c->dst);
    id<MTLTexture> s = tex_mtl(c->src), d = tex_mtl(c->dst);
    PD("T src=%llu dst=%llu %dx%dx%d→%dx%dx%d flags=%#x", c->src->serial, c->dst->serial, c->sr.width, c->sr.height, c->sr.depth, c->dr.width, c->dr.height, c->dr.depth, c->flags);
    if (!s || !d) return;
    unsigned sl = c->has_sv && c->sv.set_levels ? c->sv.base_level : 0, dl = c->has_dv && c->dv.set_levels ? c->dv.base_level : 0;
    unsigned sz0 = c->has_sv && c->sv.set_layers ? c->sv.min_layer : 0, dz0 = c->has_dv && c->dv.set_layers ? c->dv.min_layer : 0;
    PD("t src=%llu lv%u sl%u xyz=%d,%d,%d dst=%llu lv%u sl%u xyz=%d,%d,%d size=%d,%d,%d", c->src->serial, sl, sz0, c->sr.xoffset, c->sr.yoffset, c->sr.zoffset,
       c->dst->serial, dl, dz0, c->dr.xoffset, c->dr.yoffset, c->dr.zoffset, c->sr.width, c->sr.height, c->sr.depth);
    int s3 = c->src->d.target == 2, d3 = c->dst->d.target == 2, nz = c->sr.depth ? c->sr.depth : 1;
    if (no_bc() && (s.pixelFormat == MTLPixelFormatASTC_4x4_LDR || s.pixelFormat == MTLPixelFormatASTC_4x4_sRGB) && (d.pixelFormat == MTLPixelFormatRGBA8Unorm || d.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB)
        && !s3 && !d3 && c->sr.width == c->dr.width && c->sr.height == c->dr.height && (d.usage & MTLTextureUsageShaderWrite)) {   // No BC: ASTC source -> decompressed-format destination (see copy_t2t_astc)
        int ok = 1;
        for (int z = 0; z < nz && ok; z++) ok = copy_t2t_astc(s, d, sl, sz0 + c->sr.zoffset + z, dl, dz0 + c->dr.zoffset + z, c->sr.xoffset, c->sr.yoffset, c->dr.xoffset, c->dr.yoffset, c->sr.width, c->sr.height);
        if (ok) return;
    }
    if (c->sr.width != c->dr.width || c->sr.height != c->dr.height || (c->sr.depth ? c->sr.depth : 1) != (c->dr.depth ? c->dr.depth : 1) || (c->flags & ~NVN_COPY_FLAGS_ENGINE_2D_BIT & ~NVN_COPY_FLAGS_LINEAR_FILTER_BIT)
        || s.pixelFormat != d.pixelFormat || s3 != d3) {
        RED_ONCE(33, "texture→texture copy shape not implemented: %dx%dx%d→%dx%dx%d flags %#x format %lu→%lu 3D %d→%d", c->sr.width, c->sr.height, c->sr.depth, c->dr.width, c->dr.height, c->dr.depth,
                 c->flags, (unsigned long)s.pixelFormat, (unsigned long)d.pixelFormat, s3, d3);
        return;
    }
    BENC b = blit();
    if (s3)
        enc_b_copy_texture(b, s, 0, sl, MTLOriginMake(c->sr.xoffset, c->sr.yoffset, c->sr.zoffset), MTLSizeMake(c->sr.width, c->sr.height, nz), d, 0, dl, MTLOriginMake(c->dr.xoffset, c->dr.yoffset, c->dr.zoffset));
    else
        for (int z = 0; z < nz; z++)
            enc_b_copy_texture(b, s, sz0 + c->sr.zoffset + z, sl, MTLOriginMake(c->sr.xoffset, c->sr.yoffset, 0), MTLSizeMake(c->sr.width, c->sr.height, 1), d, dz0 + c->dr.zoffset + z, dl, MTLOriginMake(c->dr.xoffset, c->dr.yoffset, 0));
}

// GPU: clear a texture region with the given value (previously mislisted as a no-op, called 5 times at initialization; the initial value of a Metal private texture is undefined, and the game relies on the cleared initial value).
// Whole level and whole face, all four channels written -> open one clear-only render pass per layer / depth slice (the hardware converts the clear value by the texture format, including integer and depth);
// view with changed format: clear on a view of that format; partial region, partial channels, compressed / packaged textures (no render target usage): report a failure, to be implemented
static void clear_tex(const p_clear_tex *c) {
    if (counts_on()) g_cnt_cleartex++;
    if (c->tex) zskip_del(c->tex->serial);
    tex_gpu_write(c->tex);
    id<MTLTexture> t = tex_mtl(c->tex);
    PD("X ser=%llu view format %#x region %d,%d,%d %dx%dx%d mask %#x %s %g,%g,%g,%g", c->tex->serial, c->has_view && c->view.set_format ? c->view.format : -1, c->r.xoffset, c->r.yoffset, c->r.zoffset, c->r.width, c->r.height, c->r.depth, c->mask,
       c->is_uint ? "ui" : "f", c->is_uint ? (double)c->c.u[0] : c->c.f[0], c->is_uint ? (double)c->c.u[1] : c->c.f[1], c->is_uint ? (double)c->c.u[2] : c->c.f[2], c->is_uint ? (double)c->c.u[3] : c->c.f[3]);
    if (!t) return;
    unsigned lv = c->has_view && c->view.set_levels ? c->view.base_level : 0, l0 = c->has_view && c->view.set_layers ? c->view.min_layer : 0;
    NSUInteger w = MAX(t.width >> lv, 1u), h = MAX(t.height >> lv, 1u);
    int is3d = t.textureType == MTLTextureType3D, nz = c->r.depth ? c->r.depth : 1;
    if (c->has_view && c->view.set_format) {   // View with changed format: the clear value is interpreted in the view format (all 5 of the game's calls are the ui version with an integer view), and the clear is done on a view of the same format
        uint32_t vpf = 0; uint8_t swz[4];
        if (!nvn_fmt_to_mtl(c->view.format, &vpf, swz) || !vpf) { RED_ONCE(42, "clear-texture view format %#x has no equivalent", c->view.format); return; }
        if (tex_need_pfv(t.pixelFormat, (MTLPixelFormat)vpf) && !(t.usage & MTLTextureUsagePixelFormatView)) t = tex_upgrade_pfv(c->tex, t, (MTLPixelFormat)vpf);
        if (tex_need_pfv(t.pixelFormat, (MTLPixelFormat)vpf)) {
            id<MTLTexture> v = [t newTextureViewWithPixelFormat:(MTLPixelFormat)vpf];
            if (!v) { RED_ONCE(43, "clear-texture cannot create view: format %lu → %u", (unsigned long)t.pixelFormat, vpf); return; }
            t = v;
        }
    }
    MTLPixelFormat pf = t.pixelFormat;
    int depth = pf == MTLPixelFormatDepth32Float || pf == MTLPixelFormatDepth16Unorm || pf == MTLPixelFormatDepth32Float_Stencil8, stencil = pf == MTLPixelFormatStencil8 || pf == MTLPixelFormatDepth32Float_Stencil8;
    if (c->r.xoffset || c->r.yoffset || (NSUInteger)c->r.width != w || (NSUInteger)c->r.height != h || (c->mask & 0xf) != 0xf
        || !(t.usage & MTLTextureUsageRenderTarget)) {
        RED_ONCE(44, "clear-texture shape not implemented: region %d,%d %dx%d (this level %lux%lu) mask %#x renderable %d", c->r.xoffset, c->r.yoffset, c->r.width, c->r.height,
                 (unsigned long)w, (unsigned long)h, c->mask, !!(t.usage & MTLTextureUsageRenderTarget));
        return;
    }
    rp_end(); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    for (int z = 0; z < nz; z++) {
        RPD *rp = [RPD new];
        MTLRenderPassAttachmentDescriptor *a = depth ? rp.depthAttachment : stencil ? rp.stencilAttachment : rp.colorAttachments[0];
        a.texture = t; a.level = lv; a.loadAction = MTLLoadActionClear; a.storeAction = MTLStoreActionStore;
        if (is3d) a.depthPlane = c->r.zoffset + z; else a.slice = l0 + c->r.zoffset + z;
        if (depth) { rp.depthAttachment.clearDepth = t.pixelFormat == MTLPixelFormatDepth16Unorm ? nvn_depth16_clear_value(c->c.f[0]) : c->c.f[0];
            if (stencil) { rp.stencilAttachment.texture = t; rp.stencilAttachment.level = lv; rp.stencilAttachment.slice = a.slice; rp.stencilAttachment.loadAction = MTLLoadActionClear;
                           rp.stencilAttachment.storeAction = MTLStoreActionStore; rp.stencilAttachment.clearStencil = c->c.u[1]; } }
        else if (stencil) rp.stencilAttachment.clearStencil = c->c.u[0];
        else rp.colorAttachments[0].clearColor = c->is_uint ? MTLClearColorMake(c->c.u[0], c->c.u[1], c->c.u[2], c->c.u[3]) : MTLClearColorMake(c->c.f[0], c->c.f[1], c->c.f[2], c->c.f[3]);
        enc_r_end(enc_r_begin(rp));
    }
}

// Context description of one submit (mtl_sub_commit takes one per submit and prints it into the failure line when the command buffer errors): for the GPU memory fault on the first frame entering Travincal, the failure line had only the sequence number and error code, and it was impossible to tell what was in that submit
static const char *cctx_snap(void) {
    static char b[320]; static uint64_t p_pass, p_up, p_reup, p_ser; uint64_t up = 0, reup = 0; mtl_pkg_stats(&up, &reup);
    pthread_mutex_lock(&g_deferred_mu); unsigned long nd = (unsigned long)g_deferred.count; pthread_mutex_unlock(&g_deferred_mu);
    snprintf(b, sizeof b, "frame %llu; since the last submit: passes +%llu, first uploads +%llu, re-uploads +%llu, serial table changes +%llu; deferred-release queue %lu",
             (unsigned long long)atomic_load(&g_cur_frame), (unsigned long long)(g_stat_pass - p_pass), (unsigned long long)(up - p_up), (unsigned long long)(reup - p_reup),
             (unsigned long long)(g_ser_gen - p_ser), nd);
    p_pass = g_stat_pass; p_up = up; p_reup = reup; p_ser = g_ser_gen; return b;
}
// ---------- Power-saving mode (30 frames per second) ----------
// DM_FPS=30: present at 30 Hz (the display link and the frame rate hint of the front end follow, so a ProMotion screen lowers its refresh rate).
// mtl_fps_set changes it while running (iOS Settings page): the display link follows on the next frame (link_sync)
static _Atomic int g_fps_target;
int mtl_fps_target(void) {
    int f = atomic_load(&g_fps_target);
    if (!f) { const char *e = getenv("DM_FPS"); int v = e && atoi(e) == 30 ? 30 : 60, z = 0; atomic_compare_exchange_strong(&g_fps_target, &z, v); f = atomic_load(&g_fps_target); }
    return f;
}
void mtl_fps_set(int fps) { int v = fps == 30 ? 30 : 60; if (atomic_exchange(&g_fps_target, v) != v) MLOG("frame rate target %d fps", v); }

void mtl_exec(const uint8_t *p) {
    static int inited; if (!inited) { inited = 1; state_reset(); }
    static int dump_all = -1; if (dump_all < 0) dump_all = getenv("DM_NVN_PASSDUMP_ALL") != NULL;
    int trace = dump_all && passdump();   // Normal mode does not check the frame range per operation; the full command position is only used for the designated diagnostic frames
    for (;;) {
        op_hdr h; memcpy(&h, p, sizeof h);
        g_exec_cur = p;   // Scan start point of the store lookahead: the operation that ends the render pass (inclusive)
        if (p == g_defer_pend) { for (int gi = 0; gi < 4; gi++) if (g_defer_slots[gi].active && g_defer_slots[gi].p_end_op == p) g_defer_slots[gi].in_p = 0; g_defer_pend = NULL; }
        sdx_seq(p);
        if (trace) PD("o cmd=%p pass=%llu op=%u size=%u", p, g_stat_pass, (unsigned)h.op, (unsigned)h.size);
        if (g_hoist_n && hoist_take(p)) { if (g_fz.active && p == g_fz.rt2_op) { g_fz.phase = 2; g_rt_merged = 0; PD("F %llu merged pass enters the later pass's draws", g_stat_pass); } p += h.size; continue; }   // A pure-clear render pass already executed early / the start of a later pass already merged in   // Entering the later pass: the same-target continuation of the earlier pass ends here; the later pass reading the earlier pass's attachment is proven to be same-pixel by fz_p2_draw, and is no longer split by the continuation rule
        const void *a = p + 8;
        switch (h.op) {
            case OP_END: g_exec_cur = NULL;
                if (g_hoist_n && !g_ret_n && !g_nrest) {
                    if (g_fz.active) fz_unskip();
                    if (g_hoist_n) { MLOG("[red] pure-clear pass hoist: %d hoisted ops not reached at the end of the submit, clearing (should not happen)", g_hoist_n); g_hoist_n = 0; }
                }
                return;   // An end-of-pass triggered outside a list (present / CPU readback etc.) must not scan expired command memory: a null start point means store everything
            case OP_BEGIN: break;
            case OP_JUMP: { const uint8_t *t; memcpy(&t, a, 8); p = t; continue; }
            case OP_CALL: { uint64_t t; memcpy(&t, a, 8);
                if (g_ret_n < 16) g_ret[g_ret_n] = p + h.size; g_ret_n++;   // Return stack for lookahead: after a sub-list ends, continue looking at the caller
                mtl_exec((const uint8_t *)t); g_ret_n--; break; }
            case OP_SIGNAL_EVENT: { volatile uint32_t *val; uint32_t m, v; memcpy(&val, a, 8); memcpy(&m, (const uint8_t *)a + 8, 4); memcpy(&v, (const uint8_t *)a + 12, 4);
                PD("Y signal_event cmd=%p dst=%p mode=%u value=%u", p, val, m, v); mtl_sub_event(val, m, v); break; }
            case OP_REPORT_COUNTER: { uint64_t t, ad; memcpy(&t, a, 8); memcpy(&ad, (const uint8_t *)a + 8, 8); g_cnt_report[t & 31]++;
                PD("Q report type=%llu cmd=%p dst=%#llx", (unsigned long long)t, p, (unsigned long long)ad);
                if (t == NVN_COUNTER_TYPE_SAMPLES_PASSED) { post((post_op){3, NULL, 0, 0, ad, (uint32_t)t, vis_snapshot()}); g_vis_cur = -1;
                    occ_note(ad, g_fence + 1); }   // this submission commits with fence g_fence + 1
                else {   // counter half now, in command order (0: TIMESTAMP / TIMESTAMP_TOP report only a timestamp, the other counters are not emulated: conditional
                         // rendering at replay compares it); the timestamp half only when the GPU has run the submission. Written at replay as well, it told the game
                         // the GPU had passed that point while the work was still queued: Tears of the Kingdom's frames alternated between two poses / object sets
                         // (Zelda's cloak, the cave walls), and waiting for the GPU after every submission made it go away
                    if ((t == NVN_COUNTER_TYPE_TIMESTAMP || t == NVN_COUNTER_TYPE_TIMESTAMP_TOP) && counts_on()) { g_cnt_ts++; if (++g_cnt_sub_ts == 2) g_cnt_ts_multi++;
                        // The reports of one submission that has several, once, after frame 900: their guest heap offsets for DM_WATCHPOINT (who reads them)
                        static uint64_t logged_sub; static int nlog; uint64_t f = atomic_load(&g_cur_frame);
                        if (f >= 900 && g_cnt_sub_ts >= 2 && nlog < 12 && (!logged_sub || logged_sub == g_fence + 1)) {
                            uint8_t *al, *st, *hp; size_t aln, stn, hpn; svc_guest_layout(&al, &aln, &st, &stn, &hp, &hpn);
                            if (!logged_sub) MLOG("counts: the timestamp reports of submission %llu (frame %llu), the first one being %#llx (heap+%#llx)", (unsigned long long)(g_fence + 1),
                                                  (unsigned long long)f, (unsigned long long)g_cnt_first_ts, (unsigned long long)(g_cnt_first_ts - (uint64_t)hp));
                            logged_sub = g_fence + 1; nlog++;
                            MLOG("counts:   report %d type %llu at %#llx (heap+%#llx)", g_cnt_sub_ts, (unsigned long long)t, (unsigned long long)ad, (unsigned long long)(ad - (uint64_t)hp));
                            const char *w = getenv("DM_NVN_COUNTS_WATCH"); if (w && atoi(w) == g_cnt_sub_ts) { MLOG("counts: watching loads of report %d's timestamp", g_cnt_sub_ts); dm_watch_load(ad + 8, 8); } }
                        if (g_cnt_sub_ts == 1) g_cnt_first_ts = ad; }
                    if (ad) { uint64_t z = 0; memcpy((void *)(uintptr_t)ad, &z, sizeof z); }
                    mtl_sub_counter(ad, (uint32_t)t); }
                break; }
            case OP_RESET_COUNTER: { uint64_t t; memcpy(&t, a, 8); g_cnt_reset[t & 31]++; PD("Q reset type=%llu cmd=%p", (unsigned long long)t, p);
                if (t == NVN_COUNTER_TYPE_SAMPLES_PASSED) {
                    // Counting starts inside a pass that has no visibility buffer: the pass is split here, so the draws after the reset count in a pass
                    // that has one (they had counted nothing: the queries read 0 and Tears of the Kingdom culled the objects behind them every other
                    // frame - Zelda's cloak and the cave walls flickered)
                    if (g_enc && !g_enc_has_vis) rp_end();
                    g_vis_on = 1; g_vis_counting = 1; vis_clear(); }
                break; }
            case OP_COPY_B2B: { uint64_t s_, d, n; memcpy(&s_, a, 8); memcpy(&d, (const uint8_t *)a + 8, 8); memcpy(&n, (const uint8_t *)a + 16, 8);
                PD("Y copy_b2b cmd=%p src=%#llx dst=%#llx bytes=%llu", p, (unsigned long long)s_, (unsigned long long)d, (unsigned long long)n); mtl_sub_copy(s_, d, n); break; }
            case OP_UPDATE_UB: { uint64_t d, n; memcpy(&d, a, 8); memcpy(&n, (const uint8_t *)a + 8, 8);
                const uint8_t *data = (const uint8_t *)a + 16;
                if (passdump()) { char fv[400] = ""; size_t fo = 0; for (uint64_t q = 0; q + 4 <= n && q < 64; q += 4) { float f; memcpy(&f, data + q, 4); fo += snprintf(fv + fo, sizeof fv - fo, " %g", f); }
                    PD("Y update_ub cmd=%p dst=%#llx bytes=%llu data%s", p, (unsigned long long)d, (unsigned long long)n, fv); }
                mtl_sub_update(data, d, n);
                break; }
            case OP_SET_RT: {
                const p_set_rt *r = a;
                if (defer_begin_q(p)) break;
                int pend = R.clear_d || R.clear_s; for (int i = 0; i < 8; i++) pend |= R.clear_c[i];
                if (g_enc && !pend && R.has_rt && tbdr_on() && rt_range_same(&R.rt,r)) {
                    g_rt_merged = g_rt_range_active = g_rt_range_pending = 1; R.rt = *r; break; }
                if (g_enc && g_fz.active && g_fz.phase == 1 && fz_reuse_op(p) && !pend && g_enc_mode != 1 && R.has_rt && tbdr_on() && rt_same(&g_fz.rt1, r)) {
                    g_rt_merged = 1; if (!g_rt_merge_n++) MLOG("same-target continuation: first case pass %llu", g_stat_pass); PD("M %llu same-target continued pass", g_stat_pass); break; }
                // Do not continue a render pass opened only for a clear; one with fewer depth / stencil attachments can be continued (check the planes before drawing)
                if (g_enc && g_lay.active && !pend && lay_continue(r)) break;   // another layer of the layered pass
                if (g_enc && g_enc_mode != 1 && !pend && R.has_rt && tbdr_on() && rt_same(&R.rt, r)) { g_rt_merged = 1; if (!g_rt_merge_n++) MLOG("same-target continuation: first case pass %llu", g_stat_pass); PD("M %llu same-target continued pass", g_stat_pass); R.rt = *r; break; }
                rp_flush(); R.rt = *r; R.has_rt = 1; break;
            }
            case OP_RENDER_ENABLE: { const p_render_enable *r = a;   // SetRenderEnable: off discards clears and draws until it is on again (queue state, kept across command buffers)
                g_render_off = r->mode == 0;
                if (r->mode >= 2) {   // see occ_pending
                    if (!r->counters || occ_pending(r->counters) || occ_pending(r->counters + 16)) { g_render_off = 0; RED_ONCE(74, "SetRenderEnableConditional on a samples-passed result still on the GPU: rendering stays enabled (first case)"); }
                    else { uint64_t v0, v1; memcpy(&v0, (const void *)(uintptr_t)r->counters, 8); memcpy(&v1, (const void *)(uintptr_t)(r->counters + 16), 8);
                        g_render_off = r->mode == 2 ? v0 != v1 : v0 == v1; } }
                if (r->mode >= 2 && r->counters && passdump()) { const uint64_t *cv = (const uint64_t *)(uintptr_t)r->counters;
                    PD("e render_enable mode=%d counters=%#llx values %#llx %#llx | %#llx %#llx", r->mode, (unsigned long long)r->counters, (unsigned long long)cv[0], (unsigned long long)cv[1], (unsigned long long)cv[2], (unsigned long long)cv[3]); }
                else PD("e render_enable mode=%d counters=%#llx", r->mode, (unsigned long long)r->counters); break; }
            case OP_CLEAR_COLOR: {
                const p_clear_color *c = a;
                if (g_render_off) break;   // SetRenderEnable(false) discards clears too
                if (g_rt_merged || g_lay.active) rp_end();   // A clear arrived in a continued (or layered) render pass: end it here, and the clear is attached to the start of the next render pass as usual
                if (c->index < 0 || c->index >= R.rt.n || !R.rt.color[c->index]) { RED_ONCE(5, "color clear target %d invalid", c->index); break; }
                if (g_enc || c->mask != 0xf || !scissor_full(R.rt.color[c->index], &R.rt.cview[c->index], R.rt.has_cview[c->index])) { clear_quad(c); break; }
                R.clear_c[c->index] = 1; R.cc[c->index] = MTLClearColorMake(c->rgba[0], c->rgba[1], c->rgba[2], c->rgba[3]);
                break;
            }
            case OP_CLEAR_DS: {
                const p_clear_ds *c = a;
                if (g_render_off) break;
                if (g_rt_merged || g_lay.active) rp_end();
                if (!R.rt.depth || (!c->depth_mask && !(c->stencil_mask & 255))) break;
                // A load action clears the whole plane: inside a pass, under a partial scissor or with a partial stencil mask it is a triangle instead
                // (a scissored depth clear and a partial stencil mask used to clear the whole plane)
                if (g_enc || ((c->stencil_mask & 255) && (c->stencil_mask & 255) != 255) || !scissor_full(R.rt.depth, &R.rt.dview, R.rt.has_dview)) { clear_ds_quad(c); break; }
                if (c->depth_mask) { R.clear_d = 1; R.cd = c->depth; }
                if (c->stencil_mask) { R.clear_s = 1; R.cs = (uint32_t)c->stencil; }
                break;
            }
            case OP_DRAW: g_exec_next = p + h.size; draw(a, NULL); g_exec_next = NULL; break;   // Lookahead start point
            case OP_DRAW_IDX: g_exec_next = p + h.size; draw(NULL, a); g_exec_next = NULL; break;
            // Do not mark dirty if the state did not change (the game often re-sends the same program / state block / vertex format before each draw; the dirty flag only decides whether to re-fetch the pipeline / depth-stencil object, and equal values mean the same object)
            case OP_SCISSOR: case OP_BIND_PROGRAM: case OP_BIND_STATE: case OP_BIND_VATTR: case OP_BIND_VSTREAM: case OP_BIND_VBUF:
            case OP_BIND_UBO: case OP_BIND_SSBO: case OP_BIND_TEX: case OP_BIND_SAMP: case OP_BIND_IMG: case OP_STENCIL:
            case OP_POLY_OFFSET: case OP_VIEWPORTS: case OP_DEPTH_RANGE: case OP_BLEND_COLOR: case OP_COPY_STRIDE: case OP_COPY_IMAGE_STRIDE: case OP_DEPTH_CLAMP: case OP_PRIM_RESTART:
                state_op(h.op, a); break;
            case OP_COPY_B2T: copy_b2t(a); break;
            case OP_COPY_T2B: copy_t2b(a); break;
            case OP_COPY_T2T: copy_t2t(a); break;
            case OP_CLEAR_TEX: clear_tex(a); break;
            case OP_DISPATCH: dispatch(a); break;
            case OP_BARRIER: { int32_t bits; memcpy(&bits, a, 4); if (g_cnt_on > 0) g_cnt_bar_at = g_stat_draw; if (bits & NVN_BARRIER_INVALIDATE_TEXTURE_BIT) g_fbx_bar_at = g_stat_draw; break; }
            case OP_SET_TEX_POOL: case OP_SET_SAMP_POOL: break;
            default: break;
        }
        p += h.size;
    }
}

// ---------- Present: draw the swapchain texture to the CAMetalLayer; optional screenshot ----------
static id<MTLRenderPipelineState> g_blit_pso; static MTLPixelFormat g_blit_fmt;
static id<MTLSamplerState> g_blit_samp;
static uint64_t g_present_n;
void mtl_res_snapshot(mtl_res_count *out) {
    memset(out, 0, sizeof *out);
    out->pso = g_pso.n;
    out->cps = g_cps.n;
    out->dss = g_dss.n;
    out->shaders = (uint32_t)(g_shcache ? g_shcache.count : 0);
    os_unfair_lock_lock(&g_c1_lock);
    out->c1_bufs = (uint32_t)(g_c1_banks.count + g_c1_exclusive); out->c1_alloc = g_c1_alloc_bytes; out->c1_data = g_c1_data_bytes;
    os_unfair_lock_unlock(&g_c1_lock);
    pthread_mutex_lock(&g_smu);
    out->live_tex = g_by_serial.n;
    pthread_mutex_unlock(&g_smu);
    pthread_mutex_lock(&g_mu);
    out->pools = (uint32_t)g_npool;
    out->pool_adds = g_pool_adds;
    pthread_mutex_unlock(&g_mu);
    pthread_mutex_lock(&g_rmu);
    out->view_slots = (uint32_t)g_ntreg;
    for (int i = 0; i < g_ntreg; i++) if (g_treg[i].view) out->view_nonnull++;
    for (int i = 0; i < g_nsreg; i++) if (g_sview[i]) out->sview_nonnull++;
    pthread_mutex_unlock(&g_rmu);
}
// Screenshot on request: dm_gfx_shot_at(k, path) = take a screenshot k frames after the current one; due requests are checked at every present
#define SHOTQ_MAX 8
static struct { uint64_t frame; char path[1024]; } g_shotq[SHOTQ_MAX]; static int g_nshotq;
static pthread_mutex_t g_shotq_mu = PTHREAD_MUTEX_INITIALIZER;
static int present_encode(id<MTLCommandBuffer> cb, id<MTLTexture> src, id<MTLTexture> dst, const int crop[4]);
static int present_encode_m4(CBUF cb, id<MTLTexture> src, id<MTLTexture> dst, const int crop[4], int uv_i, id<MTLFence> wait);
// Game picture needed by the whole-window screenshot (front end window_shot; no longer does drawViewHierarchy on a Metal layer with the display link attached): at the next present, the present thread draws the same frame
// with the same encoding as the present (present_encode) into an offscreen texture of the same size as the swapchain, and after the GPU finishes hands out a CGImage in the completion callback (the callback does not block the present). Guarded by g_shotq_mu
static void (^g_grab_cb)(CGImageRef img);
void mtl_grab_next_present(void (^cb)(CGImageRef img)) { @autoreleasepool { pthread_mutex_lock(&g_shotq_mu); g_grab_cb = [cb copy]; pthread_mutex_unlock(&g_shotq_mu); } }
static void grab_present(id<MTLTexture> src, const int crop[4], CGSize sz) {
    pthread_mutex_lock(&g_shotq_mu); void (^cb)(CGImageRef) = g_grab_cb; g_grab_cb = nil; pthread_mutex_unlock(&g_shotq_mu);
    if (!cb) return;
    size_t w = (size_t)sz.width, h = (size_t)sz.height, row = w * 4;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> out = w && h ? [g_dev newTextureWithDescriptor:d] : nil; id<MTLBuffer> buf = out ? [g_dev newBufferWithLength:row * h options:MTLResourceStorageModeShared] : nil;
    id<MTLCommandBuffer> cb2 = buf ? q_cb() : nil;
    if (!cb2 || !present_encode(cb2, src, out, crop)) { MLOG("[red] full-window screenshot: offscreen encode of the game picture failed (%zux%zu)", w, h); cb(NULL); return; }
    id<MTLBlitCommandEncoder> b = [cb2 blitCommandEncoder];
    [b copyFromTexture:out sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:buf destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * h];
    [b endEncoding];
    [cb2 addCompletedHandler:^(id<MTLCommandBuffer> c) { (void)c;
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate(buf.contents, w, h, 8, row, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL; cb(img);
        CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs); }];
    [cb2 commit];
}
void dm_gfx_shot_at(long k, const char *path) {
    pthread_mutex_lock(&g_shotq_mu);
    if (g_nshotq < SHOTQ_MAX) { g_shotq[g_nshotq].frame = g_present_n + (uint64_t)(k > 0 ? k : 0); strlcpy(g_shotq[g_nshotq].path, path, sizeof g_shotq[0].path); g_nshotq++; }
    else MLOG("[red] more than %d screenshot requests, dropping %s", SHOTQ_MAX, path);
    pthread_mutex_unlock(&g_shotq_mu);
}
// DM_NVN_SHOT_OUT=WIDTHxHEIGHT (for picture quality metrics): the present-frame screenshot instead captures the result "upscaled to this resolution by present_encode", i.e. the picture the player sees on screen; screen=0 (texture dump) is unaffected
static void shot(id<MTLTexture> src, const char *path, int screen, const int crop[4]) {
    static int out_w = -1, out_h;
    if (out_w < 0) {
        out_w = 0;
        const char *e = getenv("DM_NVN_SHOT_OUT"); int w = 0, h = 0; char sep = 0, extra = 0;
        if (e && sscanf(e, "%d%c%d%c", &w, &sep, &h, &extra) == 3 && sep == 'x' && w > 0 && h > 0) { out_w = w; out_h = h; }
    }
    id<MTLTexture> read = src;
    if (out_w && screen) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:out_w height:out_h mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; d.storageMode = MTLStorageModePrivate;
        id<MTLTexture> out = [g_dev newTextureWithDescriptor:d];
        if (!out) { MLOG("[red] cannot create screenshot output texture %dx%d", out_w, out_h); return; }
        id<MTLCommandBuffer> cb = q_cb();
        if (!present_encode(cb, src, out, crop)) return;
        [cb commit]; [cb waitUntilCompleted];
        read = out;
    }
    if (read.pixelFormat != MTLPixelFormatRGBA8Unorm && read.pixelFormat != MTLPixelFormatRGBA8Unorm_sRGB &&
        read.pixelFormat != MTLPixelFormatBGRA8Unorm && read.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB) { MLOG("[red] screenshot does not support format %lu", (unsigned long)read.pixelFormat); return; }
    size_t w = read.width, h = read.height, row = w * 4;
    id<MTLBuffer> buf = [g_dev newBufferWithLength:row * h options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = q_cb();
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:read sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
              toBuffer:buf destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * h];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
    int bgra = read.pixelFormat == MTLPixelFormatBGRA8Unorm || read.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo bi = bgra ? (kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little) : (CGBitmapInfo)kCGImageAlphaNoneSkipLast;
    CGContextRef ctx = CGBitmapContextCreate(buf.contents, w, h, 8, row, cs, bi);
    CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CGImageDestinationRef dst = url ? CGImageDestinationCreateWithURL(url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL) : NULL;
    // If any step yields null (directory does not exist / not writable, bitmap context cannot be created), report a failure and return; previously it went straight to CFRelease(NULL) and crashed in CFRelease.cold (hit during a 1952-wide TEXDUMP)
    int ok = 0;
    if (!ctx || !img || !dst) MLOG("[red] screenshot %s failed: %s", path, !ctx ? "cannot create bitmap context" : !img ? "failed to get image" : "cannot write (directory missing or not writable)");
    else { CGImageDestinationAddImage(dst, img, NULL); ok = CGImageDestinationFinalize(dst); }
    if (dst) CFRelease(dst); if (url) CFRelease(url); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
    dm_shot_written(path, ok);   // Let the host write the "frozen tick" line first, then write the "success" line: the screenshot script stops the host as soon as it sees "success", and with the order reversed the log would lack the "frozen tick" line under full load (false failure in the gate check's require_log)
    MLOG("screenshot %zux%zu format %lu → %s %s", w, h, (unsigned long)read.pixelFormat, path, ok ? "success" : "failed");
    if (g_ruler_truth && getenv("DM_NVN_RULER") && !strcmp(getenv("DM_NVN_RULER"), "1") && ok) { static int shots; if (++shots == 2) g_ruler_pending = 1; }
    if (g_defer_ab >= 0 && getenv("DM_NVN_DEFER_AB") && !strcmp(getenv("DM_NVN_DEFER_AB"), "1") && ok) { static int shots; if (++shots == 2) { g_defer_ab_on = 1; MLOG("DM_NVN_DEFER_AB: second screenshot written to disk, enabling the deferred merged pass"); } }
    if (g_udc_ab >= 0 && getenv("DM_NVN_UDC_AB") && !strcmp(getenv("DM_NVN_UDC_AB"), "1") && ok) {
        static int shots;
        if (++shots == 2) { g_udc_ab_on = 1; MLOG("DM_NVN_UDC_AB: second screenshot written to disk, enabling DM_NVN_UNWRITTEN_DC"); }
    }
}
// ---------- DM_NVN_TEXDUMP=frame number:path (%d in the path is replaced with "index*100+mip level"): save each color render target used by that frame as an image ----------
// Diagnostic: before the first render pass of the next frame is opened, wait for the GPU to finish, then draw each one (the mip level used by that frame) by full-screen sampling into RGBA8 and save as PNG (float formats are clamped to [0,1])
static long g_td_frame = -2; static const char *g_td_path; static NSMutableArray *g_td_list; static int g_td_done;
static void td_dump(void);
void td_note(RPD *pd, NSUInteger nc) {
    if (g_td_frame == -2) { const char *e = getenv("DM_NVN_TEXDUMP"), *c = e ? strchr(e, ':') : NULL; g_td_frame = c ? atol(e) : -1; g_td_path = c ? c + 1 : NULL; g_td_list = [NSMutableArray array]; }
    if (g_td_frame < 0 || g_td_done) return;
    long f = (long)atomic_load(&g_cur_frame);
    if (f > g_td_frame) { td_dump(); return; }
    if (f != g_td_frame) return;
    for (NSUInteger i = 0; i < nc && i < 8; i++) {
        id<MTLTexture> t = pd.colorAttachments[i].texture; if (!t) continue;
        uint64_t ser = i < (NSUInteger)R.rt.n && R.rt.color[i] ? R.rt.color[i]->serial : 0;
        NSUInteger lv = pd.colorAttachments[i].level;
        BOOL seen = NO; for (NSArray *e in g_td_list) if ([e[1] unsignedLongLongValue] == ser && [e[2] unsignedIntegerValue] == lv) seen = YES;
        if (!seen) [g_td_list addObject:@[t, @(ser), @(lv)]];
    }
}
static void td_dump(void) {
    g_td_done = 1;
    rp_end(); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    mtl_finish_gpu();
    static id<MTLRenderPipelineState> ps; static id<MTLSamplerState> sp;
    if (!ps) {
        static const char *src_msl =
            "#include <metal_stdlib>\nusing namespace metal;\n"
            "struct V { float4 p [[position]]; float2 uv; };\n"
            "vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }\n"
            "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { float4 c = t.sample(s, in.uv); return float4(c.rgb, 1); }\n";
        NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(src_msl) options:nil error:&e];
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"vs"]; d.fragmentFunction = [lib newFunctionWithName:@"fs"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        ps = [g_dev newRenderPipelineStateWithDescriptor:d error:&e];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sp = [g_dev newSamplerStateWithDescriptor:sd];
        if (!ps) { MLOG("[red] TEXDUMP pipeline failed %s", e.localizedDescription.UTF8String); return; }
    }
    MLOG("[texdump] frame %ld, %lu color targets in total", g_td_frame, (unsigned long)g_td_list.count);
    // DM_NVN_TEXRAW=index,...: save raw bytes by texture index (including 3D; file: %d in the path is replaced with the index, suffix .raw, first-line text header: width height depth format bytes-per-row)
    for (const char *q = getenv("DM_NVN_TEXRAW"); q && *q; q = strchr(q, ',') ? strchr(q, ',') + 1 : q + strlen(q)) {
        uint64_t ser = (uint64_t)atoll(q); id o = serial_get(ser);
        id<MTLTexture> t = [o isKindOfClass:[NvPkg class]] ? ((NvPkg *)o)->tex : o;
        if (!t) { MLOG("[texraw] ser=%llu not in the serial table", ser); continue; }
        int bw, bh; NSUInteger w = t.width, h = t.height, dz = t.depth;
        size_t bpp = t.pixelFormat == MTLPixelFormatRGBA16Float ? 8 : t.pixelFormat == MTLPixelFormatRGBA32Float ? 16 : 4; (void)bw; (void)bh;
        size_t row = w * bpp, img = row * h;
        if (t.pixelFormat >= MTLPixelFormatBC1_RGBA && t.pixelFormat <= MTLPixelFormatBC7_RGBAUnorm_sRGB) {   // BC: rows of 4×4 blocks, 8 bytes (BC1 / BC4) or 16 bytes each
            size_t blk = t.pixelFormat <= MTLPixelFormatBC1_RGBA_sRGB || t.pixelFormat == MTLPixelFormatBC4_RUnorm || t.pixelFormat == MTLPixelFormatBC4_RSnorm ? 8 : 16;
            row = (w + 3) / 4 * blk; img = row * ((h + 3) / 4);
        }
        id<MTLBuffer> buf = [g_dev newBufferWithLength:img * dz options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, dz) toBuffer:buf destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:img];
        [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
        char path[1024]; snprintf(path, sizeof path, g_td_path, (int)ser); strlcat(path, ".raw", sizeof path);
        FILE *f = fopen(path, "wb"); if (f) { fprintf(f, "%lu %lu %lu %lu %zu\n", (unsigned long)w, (unsigned long)h, (unsigned long)dz, (unsigned long)t.pixelFormat, row); fwrite(buf.contents, 1, img * dz, f); fclose(f); }
        MLOG("[texraw] ser=%llu %lux%lux%lu format %lu → %s", ser, (unsigned long)w, (unsigned long)h, (unsigned long)dz, (unsigned long)t.pixelFormat, path);
    }
    for (NSArray *e in g_td_list) {
        id<MTLTexture> t = e[0]; uint64_t ser = [e[1] unsignedLongLongValue]; NSUInteger lv = [e[2] unsignedIntegerValue];
        if (t.textureType != MTLTextureType2D) { MLOG("[texdump] ser=%llu type %lu skipped", ser, (unsigned long)t.textureType); continue; }
        if (getenv("DM_NVN_SNAPRAW")) {   // Also save the raw bytes (converting an HDR target to an 8-bit image truncates; first-line text header: width height format bytes-per-row)
            NSUInteger rw = MAX(t.width >> lv, 1u), rh = MAX(t.height >> lv, 1u);
            size_t bpp = t.pixelFormat == MTLPixelFormatRGBA16Float ? 8 : t.pixelFormat == MTLPixelFormatRGBA32Float ? 16 : t.pixelFormat == MTLPixelFormatR16Float || t.pixelFormat == MTLPixelFormatR16Unorm ? 2 : 4;
            id<MTLBuffer> rb = [g_dev newBufferWithLength:rw * rh * bpp options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> rc = q_cb(); id<MTLBlitCommandEncoder> bb = [rc blitCommandEncoder];
            [bb copyFromTexture:t sourceSlice:0 sourceLevel:lv sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(rw, rh, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:rw * bpp destinationBytesPerImage:rw * rh * bpp];
            [bb endEncoding]; [rc commit]; [rc waitUntilCompleted];
            char rp_[1024]; snprintf(rp_, sizeof rp_, g_td_path, (int)(ser * 100 + lv)); strlcat(rp_, ".raw", sizeof rp_);
            FILE *f = fopen(rp_, "wb"); if (f) { fprintf(f, "%lu %lu %lu %zu\n", (unsigned long)rw, (unsigned long)rh, (unsigned long)t.pixelFormat, rw * bpp); fwrite(rb.contents, 1, rw * rh * bpp, f); fclose(f); }
        }
        id<MTLTexture> v = [t newTextureViewWithPixelFormat:t.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(lv, 1) slices:NSMakeRange(0, 1)];
        NSUInteger w = MAX(t.width >> lv, 1u), h = MAX(t.height >> lv, 1u);
        MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
        od.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; od.storageMode = MTLStorageModePrivate;
        id<MTLTexture> o = [g_dev newTextureWithDescriptor:od];
        id<MTLCommandBuffer> cb = q_cb();
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = o; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
        [en setRenderPipelineState:ps]; [en setFragmentTexture:v atIndex:0]; [en setFragmentSamplerState:sp atIndex:0];
        [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
        char path[1024]; snprintf(path, sizeof path, g_td_path, (int)(ser * 100 + lv));
        MLOG("[texdump] ser=%llu lv=%lu format %lu %lux%lu", ser, (unsigned long)lv, (unsigned long)t.pixelFormat, (unsigned long)w, (unsigned long)h);
        shot(o, path, 0, NULL);
    }
    [g_td_list removeAllObjects];
}
// DM_NVN_TEXSNAP=item,... (together with the frame number and path of DM_NVN_TEXDUMP): as soon as the selected render passes of that frame end, copy
// their color attachments and save them with the end-of-frame dump (the same target is often cleared and reused within a frame, so the end-of-frame
// state cannot show what intermediate passes wrote). Items: an in-frame pass index, a range "a-b", or "@WxH" for every pass with a color attachment
// of that size; at most 96 copies. The copy is encoded on the replay's own blit encoder, so it runs right after the pass on the GPU (a command buffer
// of its own, committed at once, ran before the replay's and copied old contents). The pass dump prints "S <pass> snapshot index <i>" for each one.
// File name index = (in-frame index * 1000 + serial) * 100 + mip level
static int g_ts_idx[64], g_ts_lo[16], g_ts_hi[16], g_ts_w[8], g_ts_h[8], g_ts_n = -1, g_ts_nr, g_ts_nsz, g_ts_on, g_ts_copies; static uint64_t g_ts_first, g_ts_curf = ~0ull;
static __strong id<MTLTexture> g_ts_att[8]; static uint64_t g_ts_ser[8]; static NSUInteger g_ts_lv[8], g_ts_sl[8]; static int g_ts_na;
void ts_note(RPD *pd, NSUInteger nc) {
    if (g_ts_n < 0) { g_ts_n = 0; const char *e = getenv("DM_NVN_TEXSNAP");
        for (const char *q = e; q && *q; q = strchr(q, ',') ? strchr(q, ',') + 1 : q + strlen(q)) {
            int a1, a2;
            if (*q == '@') { if (g_ts_nsz < 8 && sscanf(q + 1, "%dx%d", &a1, &a2) == 2) { g_ts_w[g_ts_nsz] = a1; g_ts_h[g_ts_nsz++] = a2; } }
            else if (sscanf(q, "%d-%d", &a1, &a2) == 2) { if (g_ts_nr < 16) { g_ts_lo[g_ts_nr] = a1; g_ts_hi[g_ts_nr++] = a2; } }
            else if (g_ts_n < 64) g_ts_idx[g_ts_n++] = atoi(q);
        } }
    g_ts_on = 0; if (!(g_ts_n || g_ts_nr || g_ts_nsz) || g_td_frame < 0 || g_td_done) return;
    uint64_t f = atomic_load(&g_cur_frame); if (f != g_ts_curf) { g_ts_curf = f; g_ts_first = g_stat_pass; }
    if ((long)f != g_td_frame || g_ts_copies >= 96) return;
    int idx = (int)(g_stat_pass - g_ts_first), hit = 0;
    for (int i = 0; i < g_ts_n; i++) hit |= g_ts_idx[i] == idx;
    for (int i = 0; i < g_ts_nr; i++) hit |= idx >= g_ts_lo[i] && idx <= g_ts_hi[i];
    for (NSUInteger i = 0; i < nc && i < 8 && !hit; i++) { id<MTLTexture> t = pd.colorAttachments[i].texture; if (!t) continue;
        for (int k = 0; k < g_ts_nsz; k++) hit |= (int)MAX(t.width >> pd.colorAttachments[i].level, 1u) == g_ts_w[k] && (int)MAX(t.height >> pd.colorAttachments[i].level, 1u) == g_ts_h[k]; }
    g_ts_na = 0; if (!hit) return;
    g_ts_on = idx + 1;
    PD("S %llu snapshot index %d", g_stat_pass + 1, idx);
    for (NSUInteger i = 0; i < nc && i < 8; i++) { id<MTLTexture> t = pd.colorAttachments[i].texture; if (!t) continue;
        g_ts_att[g_ts_na] = t; g_ts_ser[g_ts_na] = R.rt.color[i] ? R.rt.color[i]->serial : 0; g_ts_lv[g_ts_na] = pd.colorAttachments[i].level; g_ts_sl[g_ts_na] = pd.colorAttachments[i].slice; g_ts_na++; }
}
void ts_after(void) {
    if (!g_ts_on) return;
    for (int i = 0; i < g_ts_na && g_ts_copies < 96; i++) {
        id<MTLTexture> t = g_ts_att[i]; if (t.textureType != MTLTextureType2D && t.textureType != MTLTextureType2DArray) continue;
        NSUInteger lv = g_ts_lv[i], w = MAX(t.width >> lv, 1u), h = MAX(t.height >> lv, 1u);
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:t.pixelFormat width:w height:h mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead; d.storageMode = MTLStorageModePrivate;
        id<MTLTexture> c = [g_dev newTextureWithDescriptor:d]; if (!c) continue;
        res_add(c);
        enc_b_copy_texture(blit(), t, g_ts_sl[i], lv, MTLOriginMake(0, 0, 0), MTLSizeMake(w, h, 1), c, 0, 0, MTLOriginMake(0, 0, 0));
        [g_td_list addObject:@[c, @((uint64_t)(g_ts_on - 1) * 1000 + g_ts_ser[i]), @0]];
        g_ts_copies++;
    }
    g_ts_on = 0;
}
// Ring of actual presentation times: present sequence number -> presentedTime (seconds; -1 = dropped by the system, not presented)
#define PRING 1024
typedef struct { uint64_t n; double t; } pres_ent;
static pres_ent g_pres[PRING];
// Get the actual presentation time of the nth present (returns 0 if not ready, -1 if dropped)
double mtl_presented_time(uint64_t n) { pres_ent e = g_pres[n % PRING]; return e.n == n ? e.t : 0; }
static _Atomic uint64_t g_drawable_ns;   // Accumulated wall clock waiting for nextDrawable in present (timing instrumentation)
uint64_t mtl_drawable_ns_take(void) { return atomic_exchange(&g_drawable_ns, 0); }
// Maximum refresh rate (Hz) of the screen when there is a window; returns 0 without a window. Mac uses CoreGraphics display modes (thread-safe C interface; the present configuration is read on the game thread)
int mtl_display_hz(void) {
    if (!front_metal_layer()) return 0;
#if TARGET_OS_OSX
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(CGMainDisplayID());
    double hz = m ? CGDisplayModeGetRefreshRate(m) : 0; if (m) CGDisplayModeRelease(m);
    return (int)(hz + 0.5);
#else
    Class c = NSClassFromString(@"UIScreen"); id s = c ? [c valueForKey:@"mainScreen"] : nil;
    return s ? [[s valueForKey:@"maximumFramesPerSecond"] intValue] : 0;
#endif
}
static _Atomic uint64_t g_present_stall_ns;   // For unit tests: an extra pause before each present on the present thread (simulating a drawable that stays unavailable)
#if !DM_NVN_M3
static CAMetalLayer *g_present_layer_resident;
#endif
void mtl_present_test_stall(uint64_t ns) { g_present_stall_ns = ns; }
static void present_pipeline(MTLPixelFormat format) {
    if (!g_blit_pso || g_blit_fmt != format) {
        static const char *src_msl =
            "#include <metal_stdlib>\nusing namespace metal;\n"
            "struct V { float4 p [[position]]; float2 uv; };\n"
            "vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }\n"
            "struct Crop { float4 rect; float4 edge; };\n"
            "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) { return t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw)); }\n";
        NSError *e = nil;
        id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(src_msl) options:nil error:&e];
        if (!lib) MDIE("present shader compile failed %s", e.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = format;
        g_blit_pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
        if (!g_blit_pso) MDIE("present pipeline failed %s", e.localizedDescription.UTF8String);
        g_blit_fmt = format;
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear; sd.supportArgumentBuffers = YES;
        g_blit_samp = [g_dev newSamplerStateWithDescriptor:sd];
    }
}
// Source for presentation sampling: when the swapchain texture has an sRGB format (the game created the swapchain as RGBA8_SRGB), sample through its non-sRGB view so the screen shows the stored bytes, as the Switch's scan-out does;
// sampling it directly decodes to linear first, and the present layer (BGRA8Unorm) does not encode again, so the whole picture is too dark (public repository #36). Screenshots read the raw bytes and cannot see this.
// Views are cached per source texture, 4 of them, replacing the least recently used: presentation runs on its own queue and cannot use the deferred release of the main submission; at most 3 presents are in flight, so the replaced one is already done
static id<MTLTexture> present_src(id<MTLTexture> src) {
    MTLPixelFormat raw = MTLPixelFormatInvalid;
    for (size_t i = 0; i < sizeof g_pfv_srgb / sizeof *g_pfv_srgb; i++) if (src.pixelFormat == g_pfv_srgb[i].b) raw = g_pfv_srgb[i].a;
    if (raw == MTLPixelFormatInvalid) return src;
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER; static id<MTLTexture> cs[4], cv[4]; static uint64_t used[4], tick;
    pthread_mutex_lock(&mu);
    int k = -1, old = 0;
    for (int i = 0; i < 4; i++) { if (cs[i] == src) k = i; if (used[i] < used[old]) old = i; }
    if (k < 0) { k = old; cs[k] = src; cv[k] = [src newTextureViewWithPixelFormat:raw];
        if (!cv[k]) RED_ONCE(50, "present: cannot create a non-sRGB view of the sRGB swapchain texture (format %lu), sampling it directly (the picture will be darker, first case)", (unsigned long)src.pixelFormat);
        else MLOG("present: swapchain texture is sRGB format %lu, sampled through a view of format %lu", (unsigned long)src.pixelFormat, (unsigned long)raw); }
    used[k] = ++tick; id<MTLTexture> v = cv[k] ?: src;
    pthread_mutex_unlock(&mu);
    return v;
}
// Present samples only the valid source rectangle declared by NVN; kept separate from the raw swapchain readback screenshot. Edges are clamped to the texel centers of the valid area, so bilinear does not read the black texels outside.
static int present_encode(id<MTLCommandBuffer> cb, id<MTLTexture> src0, id<MTLTexture> dst, const int crop[4]) {
    id<MTLTexture> src = present_src(src0);
    NSUInteger cx = 0, cy = 0, cw = src.width, ch = src.height;
    if (crop && (crop[2] || crop[3])) {
        if (crop[0] < 0 || crop[1] < 0 || crop[2] <= 0 || crop[3] <= 0 ||
            (uint64_t)crop[0] + crop[2] > src.width || (uint64_t)crop[1] + crop[3] > src.height) {
            MLOG("[red] present crop out of bounds: %d,%d %dx%d / source texture %lux%lu", crop[0], crop[1], crop[2], crop[3], (unsigned long)src.width, (unsigned long)src.height); return 0;
        }
        cx = crop[0]; cy = crop[1]; cw = crop[2]; ch = crop[3];
    }
    static uint64_t last_crop[8]; uint64_t meta[8] = {src.width, src.height, cx, cy, cw, ch, dst.width, dst.height};
    if (memcmp(meta, last_crop, sizeof meta)) { memcpy(last_crop, meta, sizeof meta);
        MLOG("present crop: source texture %lux%lu, valid %lu,%lu %lux%lu → target %lux%lu", (unsigned long)src.width, (unsigned long)src.height,
             (unsigned long)cx, (unsigned long)cy, (unsigned long)cw, (unsigned long)ch, (unsigned long)dst.width, (unsigned long)dst.height); }
    present_pipeline(dst.pixelFormat);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    // Keep the game picture's aspect ratio and center it, leaving black bars in the rest (no stretching when the screen ratio differs from the game's, e.g. iPhone about 19.5:9 versus the game's 16:9);
    // when the ratio difference is < 1% (the remainder from the game width being a multiple of 8 in the full-screen setup, e.g. 1952x900 versus 2868x1320 differs by 0.17%) fill directly, leaving no few-pixel border
    double dw = dst.width, dh = dst.height, s = fmin(dw / cw, dh / ch);
    MTLViewport vp = {floor((dw - cw * s) / 2), floor((dh - ch * s) / 2), round(cw * s), round(ch * s), 0, 1};
    if (fabs((dw / dh) / ((double)cw / ch) - 1) < 0.01) vp = (MTLViewport){0, 0, dw, dh, 0, 1};
    int full = vp.originX == 0 && vp.originY == 0 && vp.width == dw && vp.height == dh;
    static double last_vp[4];   // Log one line when the viewport changes (used by the real-device screen-level acceptance screen_check.py to check the aspect ratio)
    if (memcmp(last_vp, &vp, sizeof last_vp)) { memcpy(last_vp, &vp, sizeof last_vp);
        MLOG("present viewport %.0f,%.0f %.0fx%.0f / canvas %.0fx%.0f (game picture %lux%lu)", vp.originX, vp.originY, vp.width, vp.height, dw, dh, (unsigned long)src.width, (unsigned long)src.height); }
    rp.colorAttachments[0].texture = dst; rp.colorAttachments[0].loadAction = full ? MTLLoadActionDontCare : MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setViewport:vp];
    [en setRenderPipelineState:g_blit_pso]; [en setFragmentTexture:src atIndex:0]; [en setFragmentSamplerState:g_blit_samp atIndex:0];
    float uv[8] = {(float)cx / src.width, (float)cy / src.height, (float)cw / src.width, (float)ch / src.height,
                   (cx + 0.5f) / src.width, (cy + 0.5f) / src.height, (cx + cw - 0.5f) / src.width, (cy + ch - 0.5f) / src.height};
    [en setFragmentBytes:uv length:sizeof uv atIndex:0];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [en endEncoding];
    return 1;
}
// Viewport of the game picture (cw x ch) on a dw x dh target: its aspect ratio kept and centered; a ratio difference under 1% fills the target
static MTLViewport present_vp(double dw, double dh, double cw, double ch) {
    double s = fmin(dw / cw, dh / ch);
    if (fabs((dw / dh) / (cw / ch) - 1) < 0.01) return (MTLViewport){0, 0, dw, dh, 0, 1};
    return (MTLViewport){floor((dw - cw * s) / 2), floor((dh - ch * s) / 2), round(cw * s), round(ch * s), 0, 1};
}
// ---------- MetalFX spatial upscaling of the presented picture ----------
// Mode: mtl_upscale_set (iOS Settings page), else DM_UPSCALE=metalfx; off = the present pass scales bilinearly. With it on and the picture shown
// larger than the game renders it (crop rectangle at the texture's origin), MetalFX's spatial scaler first scales the picture to its on-screen size
// and the present pass copies that 1:1.
// Metal 4 (MTL4FXSpatialScaler): neither the headers nor the documentation describe its synchronization. Logging proxies around the command buffer
// and the encoders it opens (macOS 26, Apple M5) showed: it adds a residency set of its own (useResidencySet:), encodes two render passes, and with
// `fence` set its first pass waits on that fence before the fragment stage and its last pass updates it after the fragment stage; with no fence its
// first pass waits for nothing. So (1) the present command buffer goes behind a queue-wide signal / wait of g_fx.ev (MTL4CommandQueue signalEvent:
// "after all GPU work prior to this point is complete"; the game's frames and the presents share the one queue), ordering the scaler after the game's
// frame, and (2) the present pass waits on the fence before its fragment stage. The older API (DM_NVN_M3) tracks these hazards itself.
static _Atomic int g_upscale = -1;
void mtl_upscale_set(int on) { int v = on != 0; if (atomic_exchange(&g_upscale, v) != v) MLOG("MetalFX upscaling %s", v ? "on" : "off"); }
static int upscale_on(void) {
    int m = atomic_load(&g_upscale);
    if (m < 0) { const char *e = getenv("DM_UPSCALE"); int v = e && (!strcmp(e, "metalfx") || !strcmp(e, "1")), x = -1; atomic_compare_exchange_strong(&g_upscale, &x, v); m = atomic_load(&g_upscale); }
    return m;
}
static struct {   // present thread only
    id<MTLFXSpatialScalerBase> scaler; id<MTLTexture> out;
    NSUInteger iw, ih, ow, oh; MTLPixelFormat fmt;   // iw x ih: the whole input texture (MetalFX asserts it matches the descriptor); the crop is its content size
    id<MTLFence> fence;
#if !DM_NVN_M3
    id<MTL4Compiler> compiler; id<MTLEvent> ev; uint64_t ev_n; id<MTLResidencySet> rs;
#endif
    id old[8]; int old_i;   // replaced scalers and outputs: kept for four more replacements (at most 3 presents are in flight, one replacement per present)
    int broken, state;      // broken: MetalFX unavailable here, bilinear from now on; state: what was logged last (1 upscaling, 2 not needed, 3 crop not at origin)
    NSUInteger log_cw, log_ch, log_ow, log_oh;   // the content → output sizes last logged
} g_fx;
static void fx_retire(id o) {
    if (!o) return;
    id gone = g_fx.old[g_fx.old_i]; g_fx.old[g_fx.old_i] = o; g_fx.old_i = (g_fx.old_i + 1) % 8;
#if !DM_NVN_M3
    if (gone && [gone conformsToProtocol:@protocol(MTLTexture)]) { [g_fx.rs removeAllocation:gone]; [g_fx.rs commit]; }
#else
    (void)gone;
#endif
}
static void fx_broken(const char *why) { g_fx.broken = 1; MLOG("[red] MetalFX upscaling unavailable (%s): bilinear scaling", why); }
static int fx_ready(id<MTLTexture> src, NSUInteger ow, NSUInteger oh) {
    if (g_fx.broken) return 0;
    NSUInteger cw = src.width, ch = src.height;
    if (g_fx.scaler && g_fx.iw == cw && g_fx.ih == ch && g_fx.ow == ow && g_fx.oh == oh && g_fx.fmt == src.pixelFormat) return 1;
    if (![MTLFXSpatialScalerDescriptor supportsDevice:g_dev]) { fx_broken("the device does not support the spatial scaler"); return 0; }
    if (!g_fx.fence) g_fx.fence = [g_dev newFence];
#if !DM_NVN_M3
    if (![MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev]) { fx_broken("the device does not support MetalFX on Metal 4"); return 0; }
    NSError *e = nil;
    if (!g_fx.compiler && !(g_fx.compiler = [g_dev newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&e])) { fx_broken(e.localizedDescription.UTF8String ?: "no Metal 4 compiler"); return 0; }
    if (!g_fx.rs && !(g_fx.rs = [g_dev newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&e])) { fx_broken(e.localizedDescription.UTF8String ?: "no residency set"); return 0; }
    if (!g_fx.ev) g_fx.ev = [g_dev newEvent];
#endif
    MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
    d.colorTextureFormat = d.outputTextureFormat = src.pixelFormat;
    d.inputWidth = cw; d.inputHeight = ch; d.outputWidth = ow; d.outputHeight = oh;
    d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;   // the picture's bytes are gamma encoded (the present samples the swapchain through a non-sRGB view)
#if DM_NVN_M3
    id<MTLFXSpatialScalerBase> sc = [d newSpatialScalerWithDevice:g_dev];
#else
    id<MTLFXSpatialScalerBase> sc = [d newSpatialScalerWithDevice:g_dev compiler:g_fx.compiler];
#endif
    if (!sc) { MLOG("[red] MetalFX: no spatial scaler for %lux%lu → %lux%lu format %lu", (unsigned long)cw, (unsigned long)ch, (unsigned long)ow, (unsigned long)oh, (unsigned long)src.pixelFormat); fx_broken("scaler creation failed"); return 0; }
    if ((src.usage & sc.colorTextureUsage) != sc.colorTextureUsage) { MLOG("[red] MetalFX: the game picture's usage %#lx lacks %#lx", (unsigned long)src.usage, (unsigned long)sc.colorTextureUsage); fx_broken("input texture usage"); return 0; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat width:ow height:oh mipmapped:NO];
    td.storageMode = MTLStorageModePrivate; td.usage = sc.outputTextureUsage | MTLTextureUsageShaderRead;
    id<MTLTexture> out = [g_dev newTextureWithDescriptor:td];
    if (!out) { fx_broken("output texture creation failed"); return 0; }
    fx_retire(g_fx.scaler); fx_retire(g_fx.out);
    g_fx.scaler = sc; g_fx.out = out; g_fx.iw = cw; g_fx.ih = ch; g_fx.ow = ow; g_fx.oh = oh; g_fx.fmt = src.pixelFormat;
#if !DM_NVN_M3
    [g_fx.rs addAllocation:out]; [g_fx.rs commit];
#endif
    MLOG("MetalFX spatial scaler for a %lux%lu texture → %lux%lu (format %lu)", (unsigned long)cw, (unsigned long)ch, (unsigned long)ow, (unsigned long)oh, (unsigned long)src.pixelFormat);
    return 1;
}
static void fx_state(int st) {
    if (st == g_fx.state) return;
    g_fx.state = st;
    if (st == 2) MLOG("MetalFX upscaling: the picture is not shown larger than the game renders it, bilinear");
    if (st == 3) MLOG("MetalFX upscaling: the game's crop rectangle does not start at the texture's origin, bilinear");
}
// Encodes the upscale into cb and returns its output (out_crop = the whole output; *wait = the fence the present pass must wait on), or nil: bilinear
static id<MTLTexture> fx_apply(CBUF cb, id<MTLTexture> src0, const int crop[4], id<MTLTexture> dst, int out_crop[4], id<MTLFence> *wait) {
    *wait = nil;
    if (!upscale_on()) { g_fx.state = 0; return nil; }
    if (g_fx.broken) return nil;
    id<MTLTexture> src = present_src(src0);
    NSUInteger cw = src.width, ch = src.height;
    if (crop && (crop[2] || crop[3])) {
        if (crop[0] || crop[1]) { fx_state(3); return nil; }
        if (crop[2] <= 0 || crop[3] <= 0 || (NSUInteger)crop[2] > src.width || (NSUInteger)crop[3] > src.height) return nil;   // present_encode_m4 reports it
        cw = (NSUInteger)crop[2]; ch = (NSUInteger)crop[3];
    }
    MTLViewport vp = present_vp(dst.width, dst.height, cw, ch);
    NSUInteger ow = (NSUInteger)vp.width, oh = (NSUInteger)vp.height;
    if (ow <= cw && oh <= ch) { fx_state(2); return nil; }
    if (!fx_ready(src, ow, oh)) return nil;
    fx_state(1);
    if (cw != g_fx.log_cw || ch != g_fx.log_ch || ow != g_fx.log_ow || oh != g_fx.log_oh) {   // the crop changes without a new scaler (e.g. the game lowers its resolution)
        g_fx.log_cw = cw; g_fx.log_ch = ch; g_fx.log_ow = ow; g_fx.log_oh = oh;
        MLOG("MetalFX upscales the game's %lux%lu picture to %lux%lu on screen", (unsigned long)cw, (unsigned long)ch, (unsigned long)ow, (unsigned long)oh);
    }
    id<MTLFXSpatialScalerBase> sc = g_fx.scaler;
    sc.colorTexture = src; sc.inputContentWidth = cw; sc.inputContentHeight = ch; sc.outputTexture = g_fx.out;
#if DM_NVN_M3
    [(id<MTLFXSpatialScaler>)sc encodeToCommandBuffer:cb];
#else
    sc.fence = g_fx.fence;
    [cb useResidencySet:g_fx.rs];
    [(id<MTL4FXSpatialScaler>)sc encodeToCommandBuffer:cb];
    *wait = g_fx.fence;
#endif
    out_crop[0] = out_crop[1] = 0; out_crop[2] = (int)ow; out_crop[3] = (int)oh;
    return g_fx.out;
}
#if !DM_NVN_M3
// Right before committing a command buffer that fx_apply encoded into: everything queued so far finishes before anything queued after starts
static void fx_commit_sync(void) { g_fx.ev_n++; [g_q4 signalEvent:g_fx.ev value:g_fx.ev_n]; [g_q4 waitForEvent:g_fx.ev value:g_fx.ev_n]; }
#endif
static int present_encode_m4(CBUF cb, id<MTLTexture> src0, id<MTLTexture> dst, const int crop[4], int uv_i, id<MTLFence> wait) {
    id<MTLTexture> src = present_src(src0);
    NSUInteger cx = 0, cy = 0, cw = src.width, ch = src.height;
    if (crop && (crop[2] || crop[3])) {
        if (crop[0] < 0 || crop[1] < 0 || crop[2] <= 0 || crop[3] <= 0 ||
            (uint64_t)crop[0] + crop[2] > src.width || (uint64_t)crop[1] + crop[3] > src.height) {
            MLOG("[red] present crop out of bounds: %d,%d %dx%d / source texture %lux%lu", crop[0], crop[1], crop[2], crop[3], (unsigned long)src.width, (unsigned long)src.height); return 0;
        }
        cx = crop[0]; cy = crop[1]; cw = crop[2]; ch = crop[3];
    }
    present_pipeline(dst.pixelFormat);
    double dw = dst.width, dh = dst.height;
    MTLViewport vp = present_vp(dw, dh, cw, ch);
    int full = vp.originX == 0 && vp.originY == 0 && vp.width == dw && vp.height == dh;
    RPD *rp = [RPD new];
    rp.colorAttachments[0].texture = dst;
    rp.colorAttachments[0].loadAction = full ? MTLLoadActionDontCare : MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    RENC en = [cb renderCommandEncoderWithDescriptor:rp];
    if (!en) { MLOG("[red] M4 present render encoder creation failed"); return 0; }
#if DM_NVN_M3
    [en setFragmentTexture:src atIndex:0];
    [en setFragmentSamplerState:g_blit_samp atIndex:0];
#else
    [en barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    if (wait) [en waitForFence:wait beforeEncoderStages:MTLRenderStageFragment];   // MetalFX's output (fx_apply)
    [en setArgumentTable:g_present_args atStages:MTLRenderStageFragment];
    [g_present_args setTexture:src.gpuResourceID atIndex:0];
    [g_present_args setSamplerState:g_blit_samp.gpuResourceID atIndex:0];
#endif
    float *uv = g_present_uv[uv_i].contents;
    uv[0] = (float)cx / src.width; uv[1] = (float)cy / src.height; uv[2] = (float)cw / src.width; uv[3] = (float)ch / src.height;
    uv[4] = (cx + 0.5f) / src.width; uv[5] = (cy + 0.5f) / src.height; uv[6] = (cx + cw - 0.5f) / src.width; uv[7] = (cy + ch - 0.5f) / src.height;
#if DM_NVN_M3
    [en setFragmentBuffer:g_present_uv[uv_i] offset:0 atIndex:0];
#else
    [g_present_args setAddress:g_present_uv[uv_i].gpuAddress atIndex:0];
#endif
    [en setViewport:vp]; [en setRenderPipelineState:g_blit_pso];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    m4_end(en);
    return 1;
}
static double g_link_it_tin;   // Enqueue time of the frame the display-link callback is presenting (read and written only on the display-link thread)
// DM_NVN_LIVESHOT=<first present>,<count>:<path with %d> (window mode, diagnostics): the game picture each present really reads, copied in the present's
// own command buffer after it (no GPU wait: the frames keep the pacing of play, unlike DM_NVN_SHOT, which waits for the GPU before each shot) and
// written as PNG once that command buffer completes; at most 64 consecutive presents. For what only shows on screen
static int g_live_first = -2, g_live_n; static char g_live_path[1024];
static void png_write_buf(id<MTLBuffer> buf, size_t w, size_t h, int bgra, const char *path) {
    size_t row = w * 4; CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo bi = bgra ? (kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little) : (CGBitmapInfo)kCGImageAlphaNoneSkipLast;
    CGContextRef ctx = CGBitmapContextCreate(buf.contents, w, h, 8, row, cs, bi); CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CGImageDestinationRef dst = url ? CGImageDestinationCreateWithURL(url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL) : NULL;
    int ok = 0; if (img && dst) { CGImageDestinationAddImage(dst, img, NULL); ok = CGImageDestinationFinalize(dst); }
    if (dst) CFRelease(dst); if (url) CFRelease(url); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
    MLOG("live shot %zux%zu → %s %s", w, h, path, ok ? "success" : "failed");
}
static id<MTLBuffer> live_copy(id cb, id<MTLTexture> src, uint64_t n, char *path, size_t pn) {   // M4 present command buffer; nil when this present is not captured
    if (g_live_first == -2) { g_live_first = -1; const char *e = getenv("DM_NVN_LIVESHOT"), *c = e ? strchr(e, ':') : NULL;
        if (c && sscanf(e, "%d,%d", &g_live_first, &g_live_n) == 2 && g_live_n > 0 && g_live_n <= 64) strlcpy(g_live_path, c + 1, sizeof g_live_path); else g_live_first = -1; }
    if (g_live_first < 0 || n < (uint64_t)g_live_first || n >= (uint64_t)(g_live_first + g_live_n)) return nil;
    MTLPixelFormat f = src.pixelFormat;
    if (f != MTLPixelFormatRGBA8Unorm && f != MTLPixelFormatRGBA8Unorm_sRGB && f != MTLPixelFormatBGRA8Unorm && f != MTLPixelFormatBGRA8Unorm_sRGB) { RED_ONCE(90, "live shot: format %lu not supported", (unsigned long)f); return nil; }
    size_t w = src.width, h = src.height; id<MTLBuffer> buf = [g_dev newBufferWithLength:w * h * 4 options:MTLResourceStorageModeShared]; if (!buf) return nil;
    res_add(buf); res_commit();   // resident before this command buffer is committed
    id e = enc_b_begin(cb);
#if !DM_NVN_M3
    [(id<MTL4ComputeCommandEncoder>)e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
#endif
    enc_b_copy_texture_buffer(e, src, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(w, h, 1), buf, 0, w * 4, w * h * 4);
    m4_end(e);
    snprintf(path, pn, g_live_path, (int)n);
    return buf;
}
// DM_NVN_LIVEROWS=<file> (window mode, diagnostics): at every present, 16 evenly spaced rows of the picture the present reads are copied in the present's
// command buffer (no GPU wait) and written as one line: present number, row means (luma), then each row subsampled every 8 pixels (hex). A frame that
// differs from both neighbours over the whole screen shows in these rows; DM_NVN_LIVESHOT then takes those presents in full
enum { LR_ROWS = 16, LR_RING = 8 };
static FILE *g_lr_f; static int g_lr_on = -1; static __strong id<MTLBuffer> g_lr_buf[LR_RING]; static pthread_mutex_t g_lr_mu = PTHREAD_MUTEX_INITIALIZER;
static id<MTLBuffer> live_rows(id cb, id<MTLTexture> src, uint64_t n) {
    if (g_lr_on < 0) { const char *e = getenv("DM_NVN_LIVEROWS"); g_lr_on = e && (g_lr_f = fopen(e, "w")) != NULL; if (e && !g_lr_on) MLOG("[red] DM_NVN_LIVEROWS: cannot open %s", e); }
    if (!g_lr_on) return nil;
    MTLPixelFormat f = src.pixelFormat;
    if (f != MTLPixelFormatRGBA8Unorm && f != MTLPixelFormatRGBA8Unorm_sRGB && f != MTLPixelFormatBGRA8Unorm && f != MTLPixelFormatBGRA8Unorm_sRGB) return nil;
    size_t w = src.width, h = src.height, row = w * 4; int k = (int)(n % LR_RING);
    if (!g_lr_buf[k] || g_lr_buf[k].length < row * LR_ROWS) { g_lr_buf[k] = [g_dev newBufferWithLength:row * LR_ROWS options:MTLResourceStorageModeShared]; res_add(g_lr_buf[k]); res_commit(); }
    id e = enc_b_begin(cb);
#if !DM_NVN_M3
    [(id<MTL4ComputeCommandEncoder>)e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
#endif
    for (int r = 0; r < LR_ROWS; r++) enc_b_copy_texture_buffer(e, src, 0, 0, MTLOriginMake(0, (h * (2 * r + 1)) / (2 * LR_ROWS), 0), MTLSizeMake(w, 1, 1), g_lr_buf[k], row * r, row, row);
    m4_end(e);
    return g_lr_buf[k];
}
static void live_rows_write(id<MTLBuffer> b, size_t w, uint64_t n) {   // completion handler: the presents of a ring slot never overlap (at most 3 in flight)
    const uint8_t *p = b.contents; char line[LR_ROWS * (1920 / 8 + 1) * 2 + LR_ROWS * 8 + 64]; size_t o = 0;
    o += (size_t)snprintf(line + o, sizeof line - o, "%llu", (unsigned long long)n);
    for (int r = 0; r < LR_ROWS; r++) { uint64_t s = 0; for (size_t x = 0; x < w; x++) { const uint8_t *q = p + (size_t)r * w * 4 + x * 4; s += q[0] + q[1] + q[2]; } o += (size_t)snprintf(line + o, sizeof line - o, "\t%.2f", s / (3.0 * w)); }
    for (int r = 0; r < LR_ROWS && o + 2 * (w / 8) + 4 < sizeof line; r++) { line[o++] = '\t';
        for (size_t x = 0; x < w; x += 8) { const uint8_t *q = p + (size_t)r * w * 4 + x * 4; o += (size_t)snprintf(line + o, sizeof line - o, "%02x", (q[0] + q[1] + q[2]) / 3); } }
    line[o] = 0; pthread_mutex_lock(&g_lr_mu); fprintf(g_lr_f, "%s\n", line); fflush(g_lr_f); pthread_mutex_unlock(&g_lr_mu);
}
static int present_now(const tex_t *t, double period, uint64_t frame, uint64_t ticket, const int crop[4], id<CAMetalDrawable> supplied, double target_ts) {
    if (g_present_stall_ns) { struct timespec ts = {0, (long)g_present_stall_ns}; nanosleep(&ts, NULL); }
    g_present_n++;
    if (g_use != USE_OFF && g_use != USE_DONE) use_tick();
    if (bootprof() && (g_present_n == 1 || g_present_n % 120 == 0)) {
        if (g_present_n == 1) g_bp_first_present = bp_now() - g_bp_t0;
        MLOG("[bootprof] t=%.3f s present #%llu: metallib loads %llu / %.1f ms; pipeline creations %llu / %.1f ms (all synchronous on the submit thread); warm-up claimed shaders %llu / render pipelines %llu / compute pipelines %llu; "
             "texture uploads %.1f MB / %llu first uploads + %llu re-uploads / %.1f ms; first frame presented t=%.3f s", (bp_now() - g_bp_t0) / 1e9, g_present_n,
             g_bp_lib_n, g_bp_lib_ns / 1e6, g_bp_pso_n, g_bp_pso_ns / 1e6, g_warm_claim_shaders, g_warm_claim_rps, g_warm_claim_cps,
             g_bp_up_bytes / 1048576.0, g_pkg_uploads, g_pkg_reuploads,
             g_up_total_ns / 1e6, g_bp_first_present / 1e9);
    }
    PD("X ser=%llu", t->serial);
    id<MTLTexture> src = tex_mtl(t);
    if (!src) { RED_ONCE(8, "cannot create MTLTexture for the present texture"); return 0; }
    // DM_NVN_REGLUM=x0,y0,x1,y1:file (normalized coordinates): read back this region on every present and record "present sequence number, present time ns, region mean luminance, subsampled grayscale thumbnail (hex)" (diagnostic: verify that animation speed is independent of frame rate).
    // A separate command buffer is queued after this frame's rendering (the same queue executes in submit order); does not wait for the GPU and does not disturb frame pacing
    static int rl = -1; static float rr[4]; static FILE *rlf; static pthread_mutex_t rlmu = PTHREAD_MUTEX_INITIALIZER;
    if (rl < 0) { const char *e = getenv("DM_NVN_REGLUM"), *c = e ? strchr(e, ':') : NULL;
        rl = c && sscanf(e, "%f,%f,%f,%f", &rr[0], &rr[1], &rr[2], &rr[3]) == 4 && (rlf = fopen(c + 1, "w")) != NULL;
        if (e && !rl) MLOG("[red] DM_NVN_REGLUM argument or file invalid: %s", e); }
    if (rl && (src.pixelFormat == MTLPixelFormatRGBA8Unorm || src.pixelFormat == MTLPixelFormatBGRA8Unorm || src.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB || src.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB)) {
        NSUInteger x0 = (NSUInteger)(rr[0] * src.width), y0 = (NSUInteger)(rr[1] * src.height), w = (NSUInteger)(rr[2] * src.width) - x0, h = (NSUInteger)(rr[3] * src.height) - y0;
        id<MTLBuffer> rb = [g_dev newBufferWithLength:w * h * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x0, y0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:w * 4 destinationBytesPerImage:w * h * 4];
        [b endEncoding];
        unsigned long long n = g_present_n, tns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        [cb addCompletedHandler:^(id<MTLCommandBuffer> c) { (void)c; const uint8_t *q = rb.contents; uint64_t sum = 0;
            uint8_t g[4096]; NSUInteger ng = 0;   // Subsampled grayscale thumbnail (every 4th row / column, at most 4096 points), recorded along with the mean, for per-frame image correlation analysis
            for (NSUInteger y = 0; y < h; y += 4) for (NSUInteger x = 0; x < w && ng < sizeof g; x += 4) { const uint8_t *px = q + 4 * (y * w + x); g[ng++] = (uint8_t)((px[0] + px[1] + px[2]) / 3); }
            for (NSUInteger k = 0; k < w * h; k++) sum += q[4 * k] + q[4 * k + 1] + q[4 * k + 2];
            pthread_mutex_lock(&rlmu); fprintf(rlf, "%llu\t%llu\t%.4f\t", n, tns, sum / (3.0 * w * h));
            for (NSUInteger k = 0; k < ng; k++) fprintf(rlf, "%02x", g[k]);
            fputc('\n', rlf); fflush(rlf); pthread_mutex_unlock(&rlmu); }];
        [cb commit];
    }
    // DM_NVN_SHOT=frame number[,frame number...]:path (%d in the path is replaced with the frame number)
    static long shots[16]; static int nshot = -1; static const char *shot_path;
    if (nshot < 0) {
        nshot = 0; const char *e = getenv("DM_NVN_SHOT"), *c = e ? strchr(e, ':') : NULL;
        if (c) { shot_path = c + 1; for (const char *q = e; q < c && nshot < 16; q = strchr(q, ',') ? strchr(q, ',') + 1 : c) shots[nshot++] = atol(q); }
    }
    for (int i = 0; i < nshot; i++) if ((long)g_present_n == shots[i]) { char path[1024]; snprintf(path, sizeof path, shot_path, (int)g_present_n); mtl_finish_gpu(); shot(src, path, 1, crop); }
    pthread_mutex_lock(&g_shotq_mu);
    for (int i = 0; i < g_nshotq;) if (g_present_n >= g_shotq[i].frame) { mtl_finish_gpu(); shot(src, g_shotq[i].path, 1, crop); g_shotq[i] = g_shotq[--g_nshotq]; } else i++;
    pthread_mutex_unlock(&g_shotq_mu);

    CAMetalLayer *layer = (__bridge CAMetalLayer *)front_metal_layer();
    if (!layer) return 0;
#if !DM_NVN_M3
    if (g_present_layer_resident != layer) { [g_q4 addResidencySet:layer.residencySet]; g_present_layer_resident = layer; }
#endif
#if TARGET_OS_OSX
    if (!layer.displaySyncEnabled) layer.displaySyncEnabled = YES;   // Windowed mode follows the display's vsync to prevent tearing
#endif
    present_pipeline(layer.pixelFormat);   // Same as the original path: the first frame compiles the pipeline before taking the drawable
    if (g_grab_cb) grab_present(src, crop, layer.drawableSize);   // Game picture needed by the whole-window screenshot (peek without the lock first; the real take locks inside the function)
    uint64_t dt0 = now_ns();
    id<CAMetalDrawable> dr = supplied ? supplied : [layer nextDrawable];
    if (!supplied) g_drawable_ns += now_ns() - dt0;
    if (!dr) return 0;
    int alloc_i = (int)(ticket % 3);
    if (g_present_alloc_fence[alloc_i]) {
        pthread_mutex_lock(&g_pq_mu);
        while (g_pq_done < g_present_alloc_fence[alloc_i]) pthread_cond_wait(&g_pq_cv, &g_pq_mu);
        pthread_mutex_unlock(&g_pq_mu);
    }
#if DM_NVN_M3
    CBUF cb = [g_q commandBuffer];   // older API: presentation is recorded on the command buffer (presentDrawable), so the frame reaches the screen only after its drawing is done
    int fx_crop[4]; id<MTLFence> fx_wait; id<MTLTexture> fx = fx_apply(cb, src, crop, dr.texture, fx_crop, &fx_wait);
    if (!present_encode_m4(cb, fx ?: src, dr.texture, fx ? fx_crop : crop, alloc_i, nil)) return 0;
#else
    [g_present_alloc4[alloc_i] reset];
    [g_q4 waitForDrawable:dr];
    CBUF cb = g_present_cb[alloc_i];
    [cb beginCommandBufferWithAllocator:g_present_alloc4[alloc_i]];
    int fx_crop[4]; id<MTLFence> fx_wait; id<MTLTexture> fx = fx_apply(cb, src, crop, dr.texture, fx_crop, &fx_wait);
    if (!present_encode_m4(cb, fx ?: src, dr.texture, fx ? fx_crop : crop, alloc_i, fx_wait)) { [cb endCommandBuffer]; [g_q4 signalDrawable:dr]; return 0; }
    char live_path[1024]; id<MTLBuffer> live = live_copy(cb, src, g_present_n, live_path, sizeof live_path);
    size_t live_w = src.width, live_h = src.height; int live_bgra = src.pixelFormat == MTLPixelFormatBGRA8Unorm || src.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB;
    NSString *live_file = live ? @(live_path) : nil;
    id<MTLBuffer> rows = live_rows(cb, src, g_present_n); uint64_t rows_n = g_present_n;
    [cb endCommandBuffer];
#endif
#if !DM_NVN_M3
    MTL4CommitOptions *o = [MTL4CommitOptions new];
#endif
    [FB_ON(o, cb) FB_SEL:^(FB_ARG f) {
        if (f.error) MLOG("[red] present command buffer error: %s", f.error.description.UTF8String);
        pthread_mutex_lock(&g_pq_mu); if (ticket > g_pq_done) g_pq_done = ticket; g_pq_inflight--; pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu);
#if !DM_NVN_M3
        if (live) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ png_write_buf(live, live_w, live_h, live_bgra, live_file.UTF8String); });
        if (rows) live_rows_write(rows, live_w, rows_n);
#endif
    }];
#if !DM_NVN_M3
    CBUF buffers[] = {cb};
#endif
    pthread_mutex_lock(&g_pq_mu); g_pq_inflight++; pthread_mutex_unlock(&g_pq_mu);
#if !DM_NVN_M3
    if (fx) fx_commit_sync();   // the scaler reads the finished game frame (fx_apply)
    [g_q4 commit:buffers count:1 options:o];
#endif
    if (target_ts > 0) {
        static double leads[300], e2e[300];   // e2e: game enqueue -> system-scheduled present (including the time waiting in the queue for the display-link callback), the full span of input latency that our side can read
        static uint64_t lead_n;
        leads[lead_n % 300] = (target_ts - CACurrentMediaTime()) * 1000.0; e2e[lead_n % 300] = g_link_it_tin > 0 ? (target_ts - g_link_it_tin) * 1000.0 : 0;
        lead_n++;
        if (lead_n % 300 == 0) {
            double a[300]; memcpy(a, leads, sizeof a);
            for (int i = 1; i < 300; i++) { double v = a[i]; int j = i - 1; while (j >= 0 && a[j] > v) { a[j + 1] = a[j]; j--; } a[j + 1] = v; }
            double b[300]; memcpy(b, e2e, sizeof b);
            for (int i = 1; i < 300; i++) { double v = b[i]; int j = i - 1; while (j >= 0 && b[j] > v) { b[j + 1] = b[j]; j--; } b[j + 1] = v; }
            MLOG("display link up to %llu: ticks 300, presents %llu, empty ticks %llu, stale frames dropped by coalescing %llu; submit lead before target on-screen time p50 %.3f ms / min %.3f ms; game enqueue to target on-screen time p50 %.3f ms / min %.3f / max %.3f ms",
                 (unsigned long long)g_link_tick_n, (unsigned long long)lead_n, (unsigned long long)(g_link_tick_n - lead_n),   // only frames presented through the display link (not those presented with our own drawables during a rescue)
                 (unsigned long long)g_link_dropped, a[149], a[0], b[149], b[0], b[299]);
        }
    }
#if !DM_NVN_M3
    [g_q4 signalDrawable:dr];
#endif
    g_present_alloc_fence[alloc_i] = ticket;
#if TARGET_OS_SIMULATOR   // The iOS simulator SDK has no presentation-time callback and no minimum display duration (used only for picture acceptance, display-link ticks are not counted)
    (void)period; M3_PRESENT(cb, dr);
#else
    uint64_t pn = ticket;   // Record the present time by the game's present sequence number (ticket number): hle's present statistics are taken by "the game's nth present"; in the display link path the actual present count != the game's present count (old frames get merged and dropped)
    [dr addPresentedHandler:^(id<MTLDrawable> d) {   // Actual presentation time (the time this frame is really put on screen, CACurrentMediaTime base)
        CFTimeInterval tt = d.presentedTime;
        g_pres[pn % PRING] = (pres_ent){pn, tt > 0 ? tt : -1};
    }];
    // Each frame is displayed for at least one present period: when the GPU completion time jitters around a 120 Hz refresh boundary, the paired "25 ms + 8.33 ms" stutter no longer appears
#if DM_NVN_M3
    if (target_ts <= 0 && period > 0) [cb presentDrawable:dr afterMinimumDuration:period]; else [cb presentDrawable:dr];
#else
    if (target_ts > 0) [dr present];
    else if (period > 0) [dr presentAfterMinimumDuration:period]; else [dr present];
#endif
#endif
#if DM_NVN_M3
    [cb commit];
#endif
    (void)frame;
    return 1;
}
// ---------- Present thread ----------
// NVN semantics: QueuePresentTexture only queues the present and returns immediately (the game often calls it while holding a lock; iOS real device: synchronously waiting for nextDrawable inside it
// takes about 30 ms, the lock is held about 90% of the time, and the loading thread starves). Taking the drawable, blit and present are all done on this thread in enqueue order.
// Ticket number = which enqueue it is (starting from 1); g_pq_done = the ticket number that has been processed (blit committed to the GPU queue).
// Swapchain texture return: before AcquireTexture gets a texture it waits for the ticket of that texture's previous present to be processed (mtl_present_wait), after which the commands the game draws into it
// are necessarily ordered after that blit on the GPU queue.
#define PQ 8
typedef struct { tex_t t; double period; uint64_t frame; int crop[4]; double t_in; } pq_item;   // t_in: the time the game handed this frame into the present queue (CACurrentMediaTime)
static pq_item g_pq[PQ];
static uint64_t g_pq_in;
static int present_now(const tex_t *, double, uint64_t, uint64_t, const int[4], id<CAMetalDrawable>, double);

@interface NvMetalDisplayLinkDelegate : NSObject <CAMetalDisplayLinkDelegate>
@end

// Fallback for the display link going silent while in the foreground (two smoke-test hangs before merge: the display link stopped calling back while the app was in the foreground, nobody takes the queued frames, and the game waits forever for its previous present to be processed before "acquiring the next swapchain texture"):
// when mtl_present_wait has waited longer than STALL_NS and the display link has not called back for that long, drop the waiting frame and earlier queued frames as when entering the background (accounted as dropped frames) and let the game keep running; when the display link comes back things return to normal automatically.
// One stall logs one hint line, and one line on recovery (neither is a failure); only when the same stall lasts longer than STALL_RED_NS is it a failure. All under g_pq_mu
#define STALL_NS 100000000ull
#define STALL_RED_NS 2000000000ull
static uint64_t g_stall_t0, g_stall_drop, g_stall_n; static int g_stall_red, g_stall_logged;
// The display link watchdog only recognizes the "active" state: when the App loses active status (pulling down Control Center / notifications, incoming call, system popup) and in the background the system does not call back anyway, and the picture is covered too -- the frame-drop fallback stays as before,
// but it is not counted as stuck and no failure is reported; the stall is measured from the later of "the most recent callback / the most recent activation" (A16 logs: 8–17 seconds inactive and 17 seconds in the background were both reported as "stuck in foreground")
// Rescue (from upstream d2r-mobile): once the display link has been silent for LINK_RESCUE_NS while active, stop waiting for it and let the present
// thread acquire drawables itself (mode 0, no display-link callback), so the picture keeps moving; after g_rescue_back_ns switch back to the display
// link once more, doubling that interval (cap 60 s) each time it stalls again. Seen on iPhones after pressing a volume button: the display link stopped
// while active and never came back, and the fallback alone dropped every frame for 80 s (a frozen "black screen"). Changed under g_pq_mu; the mode
// switch itself happens in link_sync on the game's present thread
#define LINK_RESCUE_NS 500000000ull
static int g_rescue_mode; static uint64_t g_rescue_back_at, g_rescue_back_ns = 3000000000ull, g_rescue_n;
__attribute__((weak)) int dm_focus_now(void) { return 1; }   // The host's hle_oe.c provides the strong definition; when graphics unit tests do not link the host it is treated as always active
__attribute__((weak)) uint64_t dm_focus_in_since(void) { return 0; }
@implementation NvMetalDisplayLinkDelegate
- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)update {
    (void)link;
    pthread_mutex_lock(&g_pq_mu);
    if (g_stall_t0) { uint64_t since = dm_focus_in_since(), t = now_ns();
        MLOG("display link recovered: this stall lasted %.0f ms (%.0f ms of it while active), fallback dropped %llu frames (stall #%llu)", (t - g_stall_t0) / 1e6, (t - (g_stall_t0 > since ? g_stall_t0 : since)) / 1e6, (unsigned long long)g_stall_drop, (unsigned long long)g_stall_n); g_stall_t0 = 0; }
    pthread_mutex_unlock(&g_pq_mu);
    pthread_mutex_lock(&g_link_mu);
    g_link_tick_ns = now_ns();
    g_link_tick_n++;
    pthread_cond_broadcast(&g_link_cv);
    pthread_mutex_unlock(&g_link_mu);
    pthread_mutex_lock(&g_pq_mu);
    if (!g_dm_present_link || g_pq_read == g_pq_in) { pthread_mutex_unlock(&g_pq_mu); return; }
    uint64_t first = g_pq_read + 1, ticket = g_pq_in;
    pq_item it = g_pq[(g_pq_in - 1) % PQ]; g_link_it_tin = it.t_in;
    g_pq_read = g_pq_in;
    if (ticket > first) { g_link_dropped += ticket - first; for (uint64_t k = first; k < ticket; k++) g_pres[k % PRING] = (pres_ent){k, -1}; }   // Old frames merged and dropped are recorded as "not presented", so the present statistics honestly count them as dropped frames
    if (ticket > 1 && g_pq_done < ticket - 1) g_pq_done = ticket - 1;
    pthread_cond_broadcast(&g_pq_cv);
    pthread_mutex_unlock(&g_pq_mu);
    int submitted;
    @autoreleasepool { submitted = present_now(&it.t, it.period, it.frame, ticket, it.crop, update.drawable, update.targetPresentationTimestamp); }
    if (!submitted) {
        pthread_mutex_lock(&g_pq_mu);
        if (ticket > g_pq_done) g_pq_done = ticket;
        pthread_cond_broadcast(&g_pq_cv);
        pthread_mutex_unlock(&g_pq_mu);
    }
}
@end

static CAMetalDisplayLink *g_link; static CFRunLoopRef g_link_rl; static int g_link_started;
static int g_link_owns_layer, g_classic_busy;   // Under g_pq_mu: nextDrawable throws while the layer has the display link object attached, so the present thread that takes its own drawable and the display link object are mutually exclusive
static int link_on(void) { return g_dm_present_link && g_link != nil; }
// Mode 1 ticks at the present rate (hle_nvn.c present_cfg: 60, or DM_PRESENT_HZ for a game whose step follows the measured frame time: 90, 120)
static _Atomic int g_link_hz = 60;
void mtl_link_set_rate(int hz) { atomic_store(&g_link_hz, hz < 30 ? 30 : hz > 120 ? 120 : hz); }
static CAFrameRateRange link_range(int mode) {
    float hz = (float)atomic_load(&g_link_hz);
    return mode == 3 ? CAFrameRateRangeMake(30, 30, 30) : mode == 2 ? CAFrameRateRangeMake(60, 120, 120) : CAFrameRateRangeMake(hz, hz, hz);
}
static int g_link_mode = 1;   // Current mode of the display link object: 1 / 2 same as g_dm_present_link, 3 = power-saving mode 30 Hz
static void *link_main(void *arg) {   // Display link thread: started when switching to display-link mode, exits when switching back to 0
    (void)arg;
    pthread_setname_np("nvn-present-link");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    CAMetalLayer *layer = (__bridge CAMetalLayer *)front_metal_layer();
    pthread_mutex_lock(&g_pq_mu); g_link_owns_layer = 1; while (g_classic_busy) pthread_cond_wait(&g_pq_cv, &g_pq_mu); pthread_mutex_unlock(&g_pq_mu);   // Wait for the present thread to finish handing over the frame it holds
    NvMetalDisplayLinkDelegate *delegate = [NvMetalDisplayLinkDelegate new];
    CAMetalDisplayLink *link = [[CAMetalDisplayLink alloc] initWithMetalLayer:layer];
    link.preferredFrameRateRange = link_range(g_link_mode);
    link.preferredFrameLatency = g_present_latency;
    link.delegate = delegate;
    [link addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    g_link_rl = CFRunLoopGetCurrent(); g_link = link;
    CFRunLoopRun();   // When switching back to mode 0 the display link object is invalidated and this thread exits (nextDrawable cannot get a drawable while the layer still has the display link object attached, so pausing alone is not enough)
    g_link_started = 0;
    return NULL;
}
static void link_sync(void) {   // Called every frame by the game's present thread: aligns the display link object's state to g_dm_present_link and the power-saving mode (can change at run time)
    static int applied, applied_hz = 60;
    if (g_rescue_mode && now_ns() >= g_rescue_back_at) {   // rescue period over: try the display link again (stall timing restarts, so the old stall does not trigger another rescue at once)
        pthread_mutex_lock(&g_pq_mu); g_dm_present_link = g_rescue_mode; g_rescue_mode = 0; g_stall_t0 = 0; g_link_tick_ns = now_ns(); pthread_mutex_unlock(&g_pq_mu);
        MLOG("display link: rescue period over, back to pacing mode %d (frame %llu)", g_dm_present_link, (unsigned long long)atomic_load(&g_cur_frame)); }
    int want = g_dm_present_link;
    if (want < 0 || want > 2) { g_dm_present_link = applied == 3 ? 1 : applied; return; }
    if (want && mtl_fps_target() == 30) want = 3;   // Power-saving mode: display link at 30 Hz
    int hz = atomic_load(&g_link_hz);
    if (want == applied && (want != 1 || hz == applied_hz || !g_link)) return;
    if (want == applied) { g_link.preferredFrameRateRange = link_range(want); MLOG("display link rate %d → %d Hz (frame %llu)", applied_hz, hz, (unsigned long long)atomic_load(&g_cur_frame)); applied_hz = hz; return; }
    applied_hz = hz;
    g_link_mode = want;
    if (!g_link_started) {
        if (!want) { applied = 0; return; }
        if (!front_metal_layer()) return;
        g_link_started = 1; pthread_t th; if (pthread_create(&th, NULL, link_main, NULL)) MDIE("failed to start the display link thread"); pthread_detach(th);
        return;   // The display link object is created on a new thread; align again next frame
    }
    CAMetalDisplayLink *link = g_link; if (!link) return;
    if (want) link.preferredFrameRateRange = link_range(want);
    else { CFRunLoopRef rl = g_link_rl; g_link = nil; CFRunLoopPerformBlock(rl, kCFRunLoopDefaultMode, ^{ [link invalidate]; pthread_mutex_lock(&g_pq_mu); g_link_owns_layer = 0; pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu); CFRunLoopStop(rl); }); CFRunLoopWakeUp(rl); }
    MLOG("present pacing mode %d → %d (frame %llu)", applied, want, (unsigned long long)atomic_load(&g_cur_frame));
    applied = want;
    pthread_mutex_lock(&g_pq_mu); pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu);
}
// Before going to the background (mtl_drain): when the display link drives presents, frames queued but not yet presented can only be taken by the display-link callback, and in the background the system no longer calls back --
// waiting as-is for "the present queue to empty" would wait forever, the enter-background callback would not return, and the system would kill the process (the process disappears within 22 seconds after switching to another App).
// These frames will not be seen anyway: discard them directly (accounted as dropped frames) and only wait for the one present already submitted to the GPU to finish.
static void present_drop_for_suspend(void) {
    pthread_mutex_lock(&g_pq_mu);
    if (g_link_owns_layer) {
        uint64_t n = g_pq_in - g_pq_read;
        for (uint64_t k = g_pq_read + 1; k <= g_pq_in; k++) g_pres[k % PRING] = (pres_ent){k, -1};
        g_link_dropped += n; g_pq_read = g_pq_in;
        while (g_pq_inflight) pthread_cond_wait(&g_pq_cv, &g_pq_mu);
        if (g_pq_done < g_pq_in) g_pq_done = g_pq_in;
        pthread_cond_broadcast(&g_pq_cv);
        if (n) MLOG("entering background: dropping %llu queued frames not yet on screen (the display link does not call back in the background)", (unsigned long long)n);
    }
    pthread_mutex_unlock(&g_pq_mu);
}
static void *present_main(void *arg) {
    (void)arg;
    pthread_setname_np("nvn-present");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    qos_class_t qc = QOS_CLASS_UNSPECIFIED; int rp = 0; pthread_get_qos_class_np(pthread_self(), &qc, &rp); atomic_store(&g_present_qos, (uint32_t)qc);
    for (;;) {
        pthread_mutex_lock(&g_pq_mu);
        while (g_pq_read == g_pq_in || g_link_owns_layer) pthread_cond_wait(&g_pq_cv, &g_pq_mu);   // In display-link mode the display-link callback takes them; an empty queue is judged by "taken"; "done" has to wait for the feedback of the present submit and lags behind taken
        pq_item it = g_pq[g_pq_read % PQ];
        uint64_t ticket = ++g_pq_read; g_classic_busy = 1;
        pthread_mutex_unlock(&g_pq_mu);
        int submitted;
        @autoreleasepool { submitted = present_now(&it.t, it.period, it.frame, ticket, it.crop, nil, 0); }
        pthread_mutex_lock(&g_pq_mu); g_classic_busy = 0; pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu);
        if (!submitted) {
            pthread_mutex_lock(&g_pq_mu);
            if (ticket > g_pq_done) g_pq_done = ticket;
            pthread_cond_broadcast(&g_pq_cv);
            pthread_mutex_unlock(&g_pq_mu);
        }
    }
    return NULL;
}
uint32_t mtl_present_qos(void) { return atomic_load(&g_present_qos); }
static void present_start(void) { pthread_t th; if (pthread_create(&th, NULL, present_main, NULL)) MDIE("failed to start the present thread"); pthread_detach(th); }
static _Atomic int g_present_discard;
void mtl_link_pause(int on);
// The short period when the front end goes to the background and waits for the game to save: presents are dropped directly (the display link does not call back in the background, enqueueing would block the game thread; nobody sees the picture anyway).
// When turned on, also clear the frames already queued: the system first stops the display-link callback and only afterwards notifies about going to the background, and in that gap the game has already filled the swapchain and is stuck at "before acquiring the next texture, wait for its previous present to be processed"
// (hle_nvn.c nvnWindowAcquireTexture -> mtl_present_wait). Without clearing, the game cannot advance a single tick during those 2.5 seconds of waiting for the save, and the save is not written (the same pattern three times in player logs: 3 frames queued, 0 submits)
void mtl_present_discard(int on) { atomic_store(&g_present_discard, on != 0); if (on) present_drop_for_suspend(); }
uint64_t mtl_present(const tex_t *t, double period, const int crop[4]) { @autoreleasepool {
    if (atomic_load(&g_present_discard)) return 0;   // Ticket number 0 = no pending present; the swapchain texture acquire does not wait
    if (t) { xv_check(t->serial, 0, 0, "present"); if (g_xv_npresent < 128) g_xv_present[g_xv_npresent++] = t->serial; }
    static pthread_once_t once = PTHREAD_ONCE_INIT; pthread_once(&once, present_start);
    link_sync();
    {   // Test switch DM_TEST_LINK_STALL=start seconds,duration seconds: counting from the first present, pause the display link at that point (imitating the display link not calling back while in the foreground) and release it when the duration is up. For verifying the fallback; not set in the product
        static double t0, at = -1, dur; static int st; double now = CACurrentMediaTime();
        if (at < 0) { at = 0; const char *e = getenv("DM_TEST_LINK_STALL"); if (e && sscanf(e, "%lf,%lf", &at, &dur) == 2 && at > 0 && dur > 0) { t0 = now; st = 1; } else at = 0; }
        if (st == 1 && link_on() && now - t0 >= at) { st = 2; mtl_link_pause(1); MLOG("DM_TEST_LINK_STALL: pausing the display link for %.1f s (frame %llu)", dur, (unsigned long long)atomic_load(&g_cur_frame)); }
        else if (st == 2 && now - t0 >= at + dur) { st = 3; mtl_link_pause(0); MLOG("DM_TEST_LINK_STALL: resuming the display link (frame %llu)", (unsigned long long)atomic_load(&g_cur_frame)); }
    }
    pthread_mutex_lock(&g_pq_mu);
    while (g_pq_in - g_pq_done >= PQ) pthread_cond_wait(&g_pq_cv, &g_pq_mu);   // Wait only when the queue is full; normally AcquireTexture blocks first
    pq_item *it = &g_pq[g_pq_in % PQ]; *it = (pq_item){*t, period, atomic_load(&g_cur_frame), {0}, CACurrentMediaTime()};
    if (crop) memcpy(it->crop, crop, sizeof it->crop);   // The current frame's state is enqueued with the ticket number, rather than reading the mutable window late on the present thread
    uint64_t tk = ++g_pq_in;
    pthread_cond_broadcast(&g_pq_cv);
    pthread_mutex_unlock(&g_pq_mu);
    return tk;
} }
// Do not wait during discard: the frame enqueued only after the flag was set (the present thread had just passed the flag check) has nobody to take it, and waiting for it would stall again; it is left for the following mtl_drain to clear
// Do not wait indefinitely in display-link mode: see the note at STALL_NS. Only frames "not yet taken by the display link" are dropped; the one already on its way to the screen is waited for until handed to the GPU (same dropping as when entering the background)
void mtl_present_wait(uint64_t tk) { @autoreleasepool {
    pthread_mutex_lock(&g_pq_mu);
    while (g_pq_done < tk && !atomic_load(&g_present_discard)) {
        if (!g_link_owns_layer) { pthread_cond_wait(&g_pq_cv, &g_pq_mu); continue; }
        if (g_pq_read >= tk) { pthread_cond_wait(&g_pq_cv, &g_pq_mu); continue; }   // This one has already been taken by the display link and is being presented: wait for it to be handed to the GPU (the GPU completion callback will wake us)
        struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_nsec += (long)STALL_NS; if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
        // Already determined to be in a stall (when the display link comes back the callback first clears g_stall_t0, then records the display-link tick time): no longer wait 100 ms in vain every frame, drop directly, and the game proceeds by its own display-link wait timeout (about two ticks)
        if (!g_stall_t0 && (pthread_cond_timedwait(&g_pq_cv, &g_pq_mu, &ts) != ETIMEDOUT || g_pq_done >= tk)) continue;
        uint64_t now = now_ns(), last = __atomic_load_n(&g_link_tick_ns, __ATOMIC_RELAXED);
        if (g_pq_read >= tk) continue;
        if (now - last < STALL_NS) { pthread_cond_timedwait(&g_pq_cv, &g_pq_mu, &ts); continue; }   // The display link is still running, it is just not this one's turn yet: keep waiting (bounded, no busy spinning)
        uint64_t n = tk - g_pq_read;
        for (uint64_t k = g_pq_read + 1; k <= tk; k++) g_pres[k % PRING] = (pres_ent){k, -1};
        g_link_dropped += n; g_pq_read = tk;
        while (g_pq_inflight) pthread_cond_wait(&g_pq_cv, &g_pq_mu);
        if (g_pq_done < tk) g_pq_done = tk;
        pthread_cond_broadcast(&g_pq_cv);
        if (!g_stall_t0) { g_stall_t0 = last ? last : now; g_stall_drop = 0; g_stall_red = 0; g_stall_logged = 0; g_stall_n++; }
        g_stall_drop += n;
        int active = dm_focus_now() == 1; uint64_t since = dm_focus_in_since(), from = g_stall_t0 > since ? g_stall_t0 : since;
        if (active && !g_stall_logged && now - from >= STALL_NS) { g_stall_logged = 1;
            MLOG("display link has not called back for %.0f ms (while active): dropping %llu queued frames not yet on screen, the game continues (stall #%llu; back to normal automatically when the link returns)", (now - from) / 1e6, (unsigned long long)n, (unsigned long long)g_stall_n); }
        if (active && !g_rescue_mode && g_dm_present_link && now - from >= LINK_RESCUE_NS) {
            g_rescue_mode = g_dm_present_link; g_dm_present_link = 0; g_rescue_n++; g_rescue_back_at = now + g_rescue_back_ns;
            MLOG("display link silent for %.0f ms while active: presenting with our own drawables (rescue #%llu), back to the display link in %.0f s", (now - from) / 1e6, (unsigned long long)g_rescue_n, g_rescue_back_ns / 1e9);
            if (g_rescue_back_ns < 60000000000ull) g_rescue_back_ns *= 2;
        }
        if (active && !g_stall_red && now - from >= STALL_RED_NS) { g_stall_red = 1; MLOG("[red] display link has not called back for %.1f s in a row while active, presenting relies entirely on fallback frame drops, the picture is frozen", (now - from) / 1e9); }
    }
    pthread_mutex_unlock(&g_pq_mu);
} }
// Wait until all queued presents have been processed (mtl_drain, the tests): goes through mtl_present_wait, so there is still a fallback when the display link stops (real device: the game called QueueFinish once while the display link was stopped,
// and this used to wait here without a timeout; nobody took the 3 queued frames and the game stalled; those two runs on Mac did not hit this call)
double mtl_link_tick_age_ms(void) { uint64_t t = __atomic_load_n(&g_link_tick_ns, __ATOMIC_RELAXED); return t ? (now_ns() - t) / 1e6 : -1; }   // front ends log it next to volume / route changes
void mtl_present_flush(void) { pthread_mutex_lock(&g_pq_mu); uint64_t h = g_pq_in; pthread_mutex_unlock(&g_pq_mu); mtl_present_wait(h); }
void mtl_stats(uint64_t *passes, uint64_t *draws) { *passes = g_stat_pass; *draws = g_stat_draw; }
void mtl_args_stats(uint64_t *enc, uint64_t *reuse) { *enc = g_stat_args_enc; *reuse = g_stat_args_reuse; }
void mtl_use_stats(uint64_t *call, uint64_t *skip) { *call = 0; *skip = 0; }
uint64_t mtl_ds_omit(void) { return g_stat_ds_omit; }
void mtl_bw(uint64_t *load, uint64_t *store, uint64_t *full) { *load = g_bw_load; *store = g_bw_store; *full = g_pass_full_rw; }
uint64_t mtl_udc_saved_bytes(void) { return g_udc_saved_bytes; }
int mtl_has_window(void) { return front_metal_layer() != NULL; }
int mtl_link_active(void) { return link_on(); }
void mtl_link_pause(int on) { CAMetalDisplayLink *l = g_link; if (l) l.paused = on != 0; }   // For testing (DM_TEST_BG): imitates the system stopping the display-link callback in the background
// Display-link ticks one frame takes at the game's present interval (game interval mode: Tears of the Kingdom presents at 2 or 3; display mode: 1)
static _Atomic int g_link_itv = 1;
void mtl_link_set_interval(int n) { atomic_store(&g_link_itv, n < 1 ? 1 : n > 4 ? 4 : n); }
int mtl_link_wait_tick(uint64_t timeout_ns) { @autoreleasepool {
    if (!mtl_link_active()) return 0;
    // Wait for the display link only when running faster than the display: if a display-link tick has already passed since the previous frame started work (this frame is already behind), start immediately instead of waiting in vain for the next display-link tick --
    // otherwise when the frame time is slightly more than one display-link period it would "miss the tick -> wait another whole tick", locking the frame rate straight to half (measured on Mac under windowed load: runs of dropped frames)
    static uint64_t started_tick;   // Display-link tick number when the previous frame started work (only the game's present thread calls this function)
    const uint64_t step = (g_dm_present_link == 2 ? 2 : 1) * (uint64_t)atomic_load(&g_link_itv);   // How many display-link ticks one frame takes: 1 with a 60 Hz display link; 2 with a 120 Hz display link (the game still outputs 60 frames); times the present interval in game interval mode
    pthread_mutex_lock(&g_link_mu);
    if (g_link_tick_n >= started_tick + step) { started_tick = g_link_tick_n; pthread_mutex_unlock(&g_link_mu); return 1; }
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += timeout_ns / 1000000000ull; ts.tv_nsec += timeout_ns % 1000000000ull;
    if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
    while (g_link_tick_n < started_tick + step) if (pthread_cond_timedwait(&g_link_cv, &g_link_mu, &ts) == ETIMEDOUT) { pthread_mutex_unlock(&g_link_mu); return 0; }
    started_tick = g_link_tick_n;
    pthread_mutex_unlock(&g_link_mu); return 1;
} }



// Called by the watchdog (no progress): writes the state of all blocking wait points on the graphics side to the log -- who is waiting for whom is visible at a glance (after switching to the Metal 4 submit model there was once a case of "ran to 900 frames then stopped, no failure line")
void mtl_wait_state_dump(void) {
    MLOG("wait point state: main fence committed %llu / completed %llu; main allocator fences [%llu %llu %llu]; upload pending %d, allocators busy [%d %d %d], seq %u, unflushed batch %d; present queue in %llu / done %llu; main command buffer encoding %d, submit thread set %d",
         (unsigned long long)g_fence, (unsigned long long)g_done, (unsigned long long)g_alloc_fence[0], (unsigned long long)g_alloc_fence[1], (unsigned long long)g_alloc_fence[2],
         atomic_load(&g_up_pending), atomic_load(&g_up_alloc_busy[0]), atomic_load(&g_up_alloc_busy[1]), atomic_load(&g_up_alloc_busy[2]), g_up_seq, g_up_cb != nil,
         (unsigned long long)g_pq_in, (unsigned long long)g_pq_done, g_cb != nil, atomic_load(&g_sub_thread_set));
}
void mtl_alloc_stats(uint64_t *waits, uint64_t *grown, int *n) { *waits = g_alloc_waits; *grown = g_alloc_grown; *n = g_alloc_n; }   // Main submit allocator pool: how many times it waited, how many times it grew, how many exist now
#pragma clang attribute pop
