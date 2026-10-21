// Encode stage (included by nvn_mtl.m, Metal 4 only). The Metal render encoder of every render pass is created, fed and ended by one worker thread
// ("B"); the replay thread ("A") keeps the NVN state, resource lookups, argument blocks, copies, dispatches and commits, and hands B packets through a
// single-producer / single-consumer ring. A sees a sentinel as its encoder while B owns a pass: the enc_r_* wrappers turn calls on it into packets, and
// the argument table addresses go the same way (B applies them in A's order, so a draw reads the addresses A set before it). A waits for B (rs_sync)
// before it opens an encoder on the command buffer itself and before it ends one. B spins (wfe) for RS_SPIN_NS on an empty ring, then sleeps on a
// semaphore; A wakes it after a publish (seq_cst store / fence / load on both sides, so a wake-up is never lost). Objects travel retained.
// Only when the TBDR rewrites are off (DM_NVN_TBDR=0: they work on the encoder at pass end and in tile passes) and encoders are not labelled.
// DM_NVN_RENDER_STREAM=1 turns it on; off by default. Measured in Tears of the Kingdom on an M5 (TBDR off, two runs each): submission time p50 lower
// in light stretches (3.1 against 3.4 ms), higher in the heavy ones (8.0 against 7.5, 6.9 against 6.6 ms): A waits for B to drain before every copy
// and dispatch between passes (about 15 a submission), and with the render-state filter the encoder calls it moves are cheap.
// Method from MacNativeGames' nvn_render_stream.h and nvn_encode_fifo.h (ly05010419/MacNativeGames, MIT; it measured replay -18 % on an M4), written anew here.
#pragma once
#include <stdatomic.h>
#include <pthread.h>
#include <dispatch/dispatch.h>

enum { RS_PSO, RS_DSS, RS_VIEWPORT, RS_SCISSOR, RS_CULL, RS_WINDING, RS_FILL, RS_BIAS, RS_CLIP, RS_STENCIL, RS_BLEND, RS_VISIBILITY, RS_ADDRESS,
       RS_INSTANCED, RS_INDEXED, RS_STORE, RS_LAYER, RS_BEGIN, RS_END };
enum { RS_CAP = 4096, RS_SPIN_NS = 200000 };
typedef struct { uint64_t op, u[8]; } rs_packet;
static struct {
    _Alignas(64) _Atomic uint64_t published;
    _Alignas(64) _Atomic uint64_t consumed;
    _Alignas(64) uint64_t produced, seen_consumed;   // A's
    _Alignas(64) uint64_t read, seen_published;      // B's
    _Alignas(64) rs_packet p[RS_CAP];
} g_rs;
static _Atomic int g_rs_sleeping;
static dispatch_semaphore_t g_rs_sem;
static int g_rs_created, g_rs_active;
static id g_rs_sentinel;
static uint64_t g_rs_passes, g_rs_packets, g_rs_syncs, g_rs_sync_ns, g_rs_full, g_rs_full_ns, g_rs_subs;
static _Atomic uint64_t g_rs_sleeps;
static int tbdr_on(void); static int enc_label_on(void);
static int rs_enabled(void) {
    static int v = -1;
    if (v < 0) { const char *e = getenv("DM_NVN_RENDER_STREAM"); v = e && atoi(e); }
    return v;
}
static inline uint64_t rs_now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static inline int rs_mine(id e) { return g_rs_active && e == g_rs_sentinel; }
static void rs_apply(id<MTL4RenderCommandEncoder> __strong *enc, const rs_packet *p) {
    const uint64_t *u = p->u; id<MTL4RenderCommandEncoder> e = *enc;
    if (p->op != RS_BEGIN && !e) MDIE("encode stage: packet %llu without an encoder", (unsigned long long)p->op);
    switch (p->op) {
        case RS_BEGIN: {
            if (e) MDIE("encode stage: a pass begun while the previous one is open");
            MTL4RenderPassDescriptor *d = (__bridge MTL4RenderPassDescriptor *)(void *)(uintptr_t)u[0];
            id<MTL4CommandBuffer> cb = (__bridge id<MTL4CommandBuffer>)(void *)(uintptr_t)u[1];
            e = [cb renderCommandEncoderWithDescriptor:d]; CFRelease((CFTypeRef)(uintptr_t)u[0]);
            if (!e) MDIE("encode stage: renderCommandEncoderWithDescriptor failed");
            [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];   // as enc_r_begin
            [e setArgumentTable:g_vt atStages:MTLRenderStageVertex]; [e setArgumentTable:g_ft atStages:MTLRenderStageFragment];
            *enc = e; break; }
        case RS_END: [e barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice]; [e endEncoding]; *enc = nil; break;   // as m4_end
        case RS_PSO: [e setRenderPipelineState:(__bridge id<MTLRenderPipelineState>)(void *)(uintptr_t)u[0]]; if (u[0]) CFRelease((CFTypeRef)(uintptr_t)u[0]); break;
        case RS_DSS: [e setDepthStencilState:(__bridge id<MTLDepthStencilState>)(void *)(uintptr_t)u[0]]; if (u[0]) CFRelease((CFTypeRef)(uintptr_t)u[0]); break;
        case RS_VIEWPORT: { MTLViewport v; memcpy(&v, u, sizeof v); [e setViewport:v]; break; }
        case RS_SCISSOR: { MTLScissorRect v; memcpy(&v, u, sizeof v); [e setScissorRect:v]; break; }
        case RS_CULL: [e setCullMode:(MTLCullMode)u[0]]; break;
        case RS_WINDING: [e setFrontFacingWinding:(MTLWinding)u[0]]; break;
        case RS_FILL: [e setTriangleFillMode:(MTLTriangleFillMode)u[0]]; break;
        case RS_BIAS: { float v[3]; memcpy(v, u, sizeof v); [e setDepthBias:v[0] slopeScale:v[1] clamp:v[2]]; break; }
        case RS_CLIP: [e setDepthClipMode:(MTLDepthClipMode)u[0]]; break;
        case RS_STENCIL: [e setStencilReferenceValue:(uint32_t)u[0]]; break;
        case RS_BLEND: { float v[4]; memcpy(v, u, sizeof v); [e setBlendColorRed:v[0] green:v[1] blue:v[2] alpha:v[3]]; break; }
        case RS_VISIBILITY: [e setVisibilityResultMode:(MTLVisibilityResultMode)u[0] offset:(NSUInteger)u[1]]; break;
        case RS_ADDRESS: [(u[0] ? g_ft : g_vt) setAddress:u[2] atIndex:(NSUInteger)u[1]]; break;
        case RS_INSTANCED: [e drawPrimitives:(MTLPrimitiveType)u[0] vertexStart:(NSUInteger)u[1] vertexCount:(NSUInteger)u[2] instanceCount:(NSUInteger)u[3] baseInstance:(NSUInteger)u[4]]; break;
        case RS_INDEXED: [e drawIndexedPrimitives:(MTLPrimitiveType)u[0] indexCount:(NSUInteger)u[1] indexType:(MTLIndexType)u[2] indexBuffer:u[3] indexBufferLength:(NSUInteger)u[4]
                                     instanceCount:(NSUInteger)u[5] baseVertex:(NSInteger)u[6] baseInstance:(NSUInteger)u[7]]; break;
        case RS_LAYER: { MTLVertexAmplificationViewMapping m = {0, (uint32_t)u[0]}; [e setVertexAmplificationCount:1 viewMappings:&m]; break; }
        case RS_STORE: if (u[0] == 1) [e setDepthStoreAction:(MTLStoreAction)u[1]]; else if (u[0] == 2) [e setStencilStoreAction:(MTLStoreAction)u[1]]; else [e setColorStoreAction:(MTLStoreAction)u[1] atIndex:(NSUInteger)u[2]]; break;
        default: MDIE("encode stage: invalid packet %llu", (unsigned long long)p->op);
    }
}
static void *rs_worker(void *unused) {
    (void)unused;
    pthread_setname_np("nvn encode stage");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    id<MTL4RenderCommandEncoder> enc = nil; uint64_t idle_since = 0;
    for (;;) {
        if (g_rs.read == g_rs.seen_published) g_rs.seen_published = atomic_load_explicit(&g_rs.published, memory_order_acquire);
        if (g_rs.read == g_rs.seen_published) {   // nothing queued: wfe for a while, then sleep until A publishes
            uint64_t now = rs_now(); if (!idle_since) idle_since = now;
            if (now - idle_since < RS_SPIN_NS) { __builtin_arm_wfe(); continue; }
            atomic_store_explicit(&g_rs_sleeping, 1, memory_order_seq_cst);
            atomic_thread_fence(memory_order_seq_cst);
            if (atomic_load_explicit(&g_rs.published, memory_order_seq_cst) == g_rs.read) { dispatch_semaphore_wait(g_rs_sem, DISPATCH_TIME_FOREVER); atomic_fetch_add_explicit(&g_rs_sleeps, 1, memory_order_relaxed); }
            atomic_store_explicit(&g_rs_sleeping, 0, memory_order_seq_cst);
            idle_since = 0; continue;
        }
        idle_since = 0;
        @autoreleasepool { rs_apply(&enc, &g_rs.p[g_rs.read & (RS_CAP - 1)]); }
        atomic_store_explicit(&g_rs.consumed, ++g_rs.read, memory_order_release);
        __builtin_arm_sev();
    }
    return NULL;
}
static inline void rs_publish(void) {   // what A queued, and B woken if it sleeps
    atomic_store_explicit(&g_rs.published, g_rs.produced, memory_order_release);
    atomic_thread_fence(memory_order_seq_cst);
    __builtin_arm_sev();
    if (atomic_load_explicit(&g_rs_sleeping, memory_order_seq_cst)) dispatch_semaphore_signal(g_rs_sem);
}
static void rs_put(rs_packet p, int publish) {
    if (g_rs.produced - g_rs.seen_consumed == RS_CAP) {
        g_rs.seen_consumed = atomic_load_explicit(&g_rs.consumed, memory_order_acquire);
        if (g_rs.produced - g_rs.seen_consumed == RS_CAP) {   // ring full: B is behind (counted: A time lost to B)
            uint64_t t0 = rs_now(); g_rs_full++;
            do { rs_publish(); __builtin_arm_wfe(); g_rs.seen_consumed = atomic_load_explicit(&g_rs.consumed, memory_order_acquire); } while (g_rs.produced - g_rs.seen_consumed == RS_CAP);
            g_rs_full_ns += rs_now() - t0;
        }
    }
    g_rs.p[g_rs.produced++ & (RS_CAP - 1)] = p; g_rs_packets++;
    if (publish) rs_publish();
}
static void rs_sync(void) {   // A: B has done everything queued so far
    if (!g_rs_created) return;
    if (g_rs_active) MDIE("encode stage: sync inside a streamed pass");
    rs_publish();
    uint64_t t0 = rs_now();
    while (atomic_load_explicit(&g_rs.consumed, memory_order_acquire) != g_rs.produced) {
        __builtin_arm_wfe();
        if (rs_now() - t0 > 2000000000ull) MDIE("encode stage: B did not drain in 2 s");
    }
    g_rs_syncs++; g_rs_sync_ns += rs_now() - t0;
}
static int rs_stream_pass(void) {   // whether the next render pass is encoded by B
    if (!rs_enabled() || tbdr_on() || enc_label_on()) return 0;
    if (!g_rs_created) {
        g_rs_sentinel = [NSObject new]; g_rs_sem = dispatch_semaphore_create(0);
        pthread_t th; pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setstacksize(&at, 1 << 20);
        if (pthread_create(&th, &at, rs_worker, NULL)) MDIE("encode stage: worker thread creation failed");
        pthread_detach(th); g_rs_created = 1;
        MLOG("encode stage: render passes are encoded on their own thread (DM_NVN_RENDER_STREAM=1)");
    }
    return 1;
}
static id rs_pass_begin(MTL4RenderPassDescriptor *d, id cb) {
    if (g_rs_active) MDIE("encode stage: a pass begun while another is open");
    g_rs_active = 1; g_rs_passes++;
    rs_put((rs_packet){.op = RS_BEGIN, .u = {(uint64_t)(uintptr_t)CFBridgingRetain(d), (uint64_t)(uintptr_t)(__bridge void *)cb}}, 1);
    return g_rs_sentinel;
}
static void rs_pass_end(void) { rs_put((rs_packet){.op = RS_END}, 1); g_rs_active = 0; }
static inline void rs_op(unsigned op, uint64_t a, uint64_t b, uint64_t c) { rs_put((rs_packet){.op = op, .u = {a, b, c}}, 0); }
static inline void rs_obj(unsigned op, id o) { rs_put((rs_packet){.op = op, .u = {(uint64_t)(uintptr_t)(o ? CFBridgingRetain(o) : NULL)}}, 0); }
static inline void rs_bytes(unsigned op, const void *v, size_t n) { rs_packet p = {.op = op}; memcpy(p.u, v, n); rs_put(p, 0); }
static void rs_sub_end(void) {   // end of a submission: B drained; a line every 1800 submissions
    if (!g_rs_created) return;
    rs_sync();
    if (++g_rs_subs % 1800) return;
    static uint64_t lp, ls, lf, lsn;
    MLOG("encode stage up to submission %llu: %llu passes, %.0f packets a submission; waits for B %.3f ms a submission (%llu in all), ring full %.3f ms a submission (%llu times); B slept %llu times",
         (unsigned long long)g_rs_subs, (unsigned long long)g_rs_passes, (g_rs_packets - lp) / 1800.0, (g_rs_sync_ns - ls) / 1800.0 / 1e6, (unsigned long long)g_rs_syncs,
         (g_rs_full_ns - lf) / 1800.0 / 1e6, (unsigned long long)g_rs_full, (unsigned long long)(atomic_load(&g_rs_sleeps) - lsn));
    lp = g_rs_packets; ls = g_rs_sync_ns; lf = g_rs_full_ns; lsn = atomic_load(&g_rs_sleeps);
}
