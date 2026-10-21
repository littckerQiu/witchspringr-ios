// NVN null device unit tests: look up addresses from nvnBootstrapLoader the way the game does and go all the way to present; all expected values are hand-calculated, without calling the implementation under test.
// For build and run see gfx/tests/Makefile (make -C gfx/tests).
#include "../nvn/hle_nvn.c"
const dm_game_profile dm_game = { .id = "test", .nvn_api_major = 55, .nvn_api_minor = 15, .nvn_c2 = {0x168, 128, 0x568, 128, 0x120, 8}, .nvn_depth_mode = 1 };   // hle_nvn.c reports the NVN API version and sets the c[2] layout from the profile
uint64_t g_t0_ns;   // process start time from host main.c (used by hle_nvn's per-frame @t_s); unit test stub
void dm_touch_screen(int w, int h) { (void)w; (void)h; }   // touch coordinate space from host hle_touch.c (called by hle_nvn WindowSetCrop); unit test stub
#include "../tex/nvn_deswizzle.h"
#include <time.h>
void *front_metal_layer(void) { return NULL; }   // no window in unit tests: present only counts
module_t *module_of(const void *p) { (void)p; return NULL; }   // no guest modules in unit tests
module_t g_mod[MAX_MOD]; int g_nmod;                            // host symbols that crash.c depends on
void svc_thread_dump(void) {}
void crash_install(void);
void nvn_present_config(int hz, int display_mode);
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }

static int g_fail, g_n;
#define EXPECT(name, want, got) do { long long w_ = (long long)(want), g_ = (long long)(got); g_n++;                 \
    printf("%-44s expected %-12lld → got %-12lld %s\n", name, w_, g_, w_ == g_ ? "✓" : "✗"); if (w_ != g_) g_fail++; } while (0)

#define P(name) ((NVNT_##name)proc(#name))
static PFNNVNDEVICEGETPROCADDRESSPROC gpa; static NVNdevice dev;
static void *proc(const char *n) { void *p = (void *)gpa(&dev, n); if (!p) { printf("address lookup failed %s\n", n); exit(1); } return p; }

// Command memory callback: hands out a new 256-byte memory segment each time (forces a multi-segment JUMP chain)
static uint8_t g_cmdmem[64 * 1024]; static size_t g_cmdoff; static int g_cb_calls; static NVNmemoryPool g_cmdpool;
static void mem_cb(NVNcommandBuffer *c, NVNcommandBufferMemoryEvent ev, size_t minsz, void *data) {
    (void)data; g_cb_calls++;
    if (ev != NVN_COMMAND_BUFFER_MEMORY_EVENT_OUT_OF_COMMAND_MEMORY) return;
    size_t n = minsz > 256 ? minsz : 256;
    P(nvnCommandBufferAddCommandMemory)(c, &g_cmdpool, (ptrdiff_t)g_cmdoff, n); g_cmdoff += n;
}

// Suspend unit test: do the submit on another thread
static _Atomic int g_sstarted, g_sdone; static pthread_mutex_t g_smu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t g_scv = PTHREAD_COND_INITIALIZER;
static NVNqueue *g_sq; static NVNcommandHandle g_sh; static NVNT_nvnQueueSubmitCommands g_sub;
static void *susp_thr(void *a) { (void)a; pthread_mutex_lock(&g_smu); atomic_store(&g_sstarted, 1); pthread_cond_broadcast(&g_scv); pthread_mutex_unlock(&g_smu); g_sub(g_sq, 1, &g_sh); atomic_store(&g_sdone, 1); return NULL; }
static int wait_started(void) { struct timespec dl; clock_gettime(CLOCK_REALTIME, &dl); dl.tv_sec += 10; pthread_mutex_lock(&g_smu); while (!atomic_load(&g_sstarted) && pthread_cond_timedwait(&g_scv, &g_smu, &dl) == 0) {} int ok = atomic_load(&g_sstarted); pthread_mutex_unlock(&g_smu); return ok; }

// Section 5a: one recording of n BIND_UBO records (addresses base + 0x100 * i) in a 512-byte window at off of the test pool (off < 0: the window already added)
static NVNcommandBuffer g_tc; static NVNmemoryPool g_tcpool;
static NVNcommandHandle rec_binds(ptrdiff_t off, int n, uint64_t base) {
    if (off >= 0) P(nvnCommandBufferAddCommandMemory)(&g_tc, &g_tcpool, off, 512);
    P(nvnCommandBufferBeginRecording)(&g_tc);
    for (int i = 0; i < n; i++) P(nvnCommandBufferBindUniformBuffer)(&g_tc, NVN_SHADER_STAGE_VERTEX, i & 7, (NVNbufferAddress)(base + 0x100 * (uint64_t)i), 256);
    return P(nvnCommandBufferEndRecording)(&g_tc);
}
// The first JUMP of a recording (NULL = none), and where it is
static const uint8_t *jump_of(NVNcommandHandle h, const uint8_t **at) {
    for (const uint8_t *p = (const uint8_t *)(uintptr_t)h;;) {
        op_hdr x; memcpy(&x, p, sizeof x);
        if (x.op == OP_JUMP) { const uint8_t *t; memcpy(&t, p + 8, 8); if (at) *at = p; return t; }
        if (x.op == OP_END || x.size < 8) return NULL;
        p += x.size;
    }
}
// Whether the recording's BIND_UBO addresses, following JUMPs up to END, are exactly base + 0x100 * i for i = 0..n-1
static int binds_are(NVNcommandHandle h, uint64_t base, int n) {
    int k = 0;
    for (const uint8_t *p = (const uint8_t *)(uintptr_t)h;;) {
        op_hdr x; memcpy(&x, p, sizeof x);
        if (x.op == OP_JUMP) { memcpy(&p, p + 8, 8); continue; }
        if (x.op == OP_END) return k == n;
        if (x.op == OP_BIND_UBO) { p_bind_buf b; memcpy(&b, p + 8, sizeof b); if (k >= n || b.addr != base + 0x100 * (uint64_t)k) return 0; k++; }
        p += x.size;
    }
}
// hle_nvn.c's verdict on the host segment starting at seg: 1 linked from a live JUMP, 0 not, -1 no such segment
static int seg_a_linked(const uint8_t *seg) {
    pthread_mutex_lock(&g_hostseg_mu); int r = -1;
    for (int i = 0; i < g_nhostseg; i++) if (g_hostseg[i].mem == seg) r = hostseg_linked(i, 0);
    pthread_mutex_unlock(&g_hostseg_mu); return r;
}

static size_t tex_size(int fmt, int w, int h, int flags, size_t *align) {
    NVNtextureBuilder tb;
    P(nvnTextureBuilderSetDevice)(&tb, &dev); P(nvnTextureBuilderSetDefaults)(&tb);
    P(nvnTextureBuilderSetFlags)(&tb, flags); P(nvnTextureBuilderSetTarget)(&tb, NVN_TEXTURE_TARGET_2D);
    P(nvnTextureBuilderSetWidth)(&tb, w); P(nvnTextureBuilderSetHeight)(&tb, h); P(nvnTextureBuilderSetFormat)(&tb, fmt);
    if (align) *align = P(nvnTextureBuilderGetStorageAlignment)(&tb);
    return P(nvnTextureBuilderGetStorageSize)(&tb);
}

int main(void) {
    crash_install();   // the same SIGSEGV / SIGBUS handling as production (the page-fault hook is dispatched from within it)
    // 1. Bootstrap address lookup: bootstrap gets GetProcAddress, then uses it to get all the names
    PFNNVNBOOTSTRAPLOADERPROC boot = (PFNNVNBOOTSTRAPLOADERPROC)h_nvnBootstrapLoader;
    gpa = (PFNNVNDEVICEGETPROCADDRESSPROC)boot("nvnDeviceGetProcAddress");
    EXPECT("bootstrap gets GetProcAddress, non-null", 1, gpa != NULL);
    int nonnull = 0; for (unsigned i = 0; i < NVN_NFUNC; i++) nonnull += gpa(NULL, nvn_names[i]) != NULL;
    EXPECT("every name in the table gets an address", NVN_NFUNC, nonnull);
    EXPECT("address lookup of an unknown name returns null", 0, gpa(NULL, "nvnNoSuchFunction") != NULL);

    // 2. Device
    NVNdeviceBuilder db; P(nvnDeviceBuilderSetDefaults)(&db); P(nvnDeviceBuilderSetFlags)(&db, 0);
    EXPECT("DeviceInitialize succeeds", 1, P(nvnDeviceInitialize)(&dev, &db));
    int v; P(nvnDeviceGetInteger)(&dev, NVN_DEVICE_INFO_UNIFORM_BUFFER_ALIGNMENT, &v);
    EXPECT("uniform buffer alignment (measured 256 on X1)", 256, v);
    P(nvnDeviceGetInteger)(&dev, NVN_DEVICE_INFO_TEXTURE_DESCRIPTOR_SIZE, &v); EXPECT("texture descriptor size (32)", 32, v);
    P(nvnDeviceGetInteger)(&dev, NVN_DEVICE_INFO_QUEUE_COMMAND_MEMORY_MIN_SIZE, &v); EXPECT("queue command memory minimum (65536)", 65536, v);

    // 3. Memory pool: GPU address = the storage address given by the game
    static uint8_t poolmem[1 << 20] __attribute__((aligned(4096)));
    NVNmemoryPoolBuilder pb; NVNmemoryPool pool;
    P(nvnMemoryPoolBuilderSetDevice)(&pb, &dev); P(nvnMemoryPoolBuilderSetDefaults)(&pb);
    P(nvnMemoryPoolBuilderSetStorage)(&pb, poolmem, sizeof poolmem); P(nvnMemoryPoolBuilderSetFlags)(&pb, 0x24);
    EXPECT("MemoryPoolInitialize succeeds", 1, P(nvnMemoryPoolInitialize)(&pool, &pb));
    EXPECT("pool GPU address = storage address", (long long)(uintptr_t)poolmem, P(nvnMemoryPoolGetBufferAddress)(&pool));
    EXPECT("pool mapping = storage address", (long long)(uintptr_t)poolmem, (uintptr_t)P(nvnMemoryPoolMap)(&pool));
    EXPECT("pool flags read back unchanged", 0x24, P(nvnMemoryPoolGetFlags)(&pool));
    EXPECT("pool size read back unchanged", (long long)sizeof poolmem, P(nvnMemoryPoolGetSize)(&pool));

    // 3b. Buffers: address / mapping = pool storage + offset; a buffer past the end of the pool fails to initialize (Unity calls SetDevice before SetDefaults, so the device must be kept)
    {
        NVNbufferBuilder bb; NVNbuffer buf;
        P(nvnBufferBuilderSetDevice)(&bb, &dev); P(nvnBufferBuilderSetDefaults)(&bb);
        EXPECT("BufferBuilderSetDefaults keeps the device", (long long)(uintptr_t)&dev, (uintptr_t)((buf_builder_t *)&bb)->dev);
        P(nvnBufferBuilderSetStorage)(&bb, &pool, 0x200, 0x400);
        EXPECT("BufferInitialize succeeds", 1, P(nvnBufferInitialize)(&buf, &bb));
        EXPECT("buffer address = pool + offset", (long long)(uintptr_t)(poolmem + 0x200), P(nvnBufferGetAddress)(&buf));
        EXPECT("buffer mapping = pool + offset", (long long)(uintptr_t)(poolmem + 0x200), (uintptr_t)P(nvnBufferMap)(&buf));
        EXPECT("buffer size", 0x400, P(nvnBufferGetSize)(&buf));
        EXPECT("buffer's pool", (long long)(uintptr_t)&pool, (uintptr_t)P(nvnBufferGetMemoryPool)(&buf));
        P(nvnBufferBuilderSetStorage)(&bb, &pool, sizeof poolmem - 0x100, 0x200);
        EXPECT("buffer past the end of the pool fails to initialize", 0, P(nvnBufferInitialize)(&buf, &bb));
    }

    // 3b'. Texture view swizzle: kept in the 10-byte view (Tears of the Kingdom keeps game fields right after its views; a 12-byte view_t overwrote them),
    // marked as set even for the identity (a set view property replaces the texture's), other fields untouched; a value outside 0..5 is not stored
    {
        uint8_t raw[16]; memset(raw, 0xa5, sizeof raw); NVNtextureView *v = (NVNtextureView *)raw;
        P(nvnTextureViewSetDefaults)(v);
        EXPECT("SetDefaults clears exactly 10 bytes", 0xa5, raw[10]);
        P(nvnTextureViewSetLevels)(v, 3, 9); P(nvnTextureViewSetFormat)(v, NVN_FORMAT_RGBA8_SRGB);
        P(nvnTextureViewSetSwizzle)(v, NVN_TEXTURE_SWIZZLE_B, NVN_TEXTURE_SWIZZLE_G, NVN_TEXTURE_SWIZZLE_R, NVN_TEXTURE_SWIZZLE_ONE);
        const view_t *w = (const view_t *)raw;
        EXPECT("view swizzle set", 1, w->set_swz);
        EXPECT("view swizzle r = B", NVN_TEXTURE_SWIZZLE_B, w->swz_r); EXPECT("view swizzle g = G", NVN_TEXTURE_SWIZZLE_G, w->swz_g);
        EXPECT("view swizzle b = R", NVN_TEXTURE_SWIZZLE_R, w->swz_b); EXPECT("view swizzle a = ONE", NVN_TEXTURE_SWIZZLE_ONE, w->swz_a);
        EXPECT("levels kept beside the swizzle", 3 * 16 + 9, w->base_level * 16 + w->nlevels); EXPECT("format kept", NVN_FORMAT_RGBA8_SRGB, w->format);
        EXPECT("swizzle leaves the bytes after the view alone", 0xa5, raw[10]);
        P(nvnTextureViewSetDefaults)(v); P(nvnTextureViewSetSwizzle)(v, NVN_TEXTURE_SWIZZLE_R, NVN_TEXTURE_SWIZZLE_G, NVN_TEXTURE_SWIZZLE_B, NVN_TEXTURE_SWIZZLE_A);
        EXPECT("identity view swizzle still counts as set", 1, w->set_swz);
        P(nvnTextureViewSetDefaults)(v); P(nvnTextureViewSetSwizzle)(v, (NVNtextureSwizzle)6, NVN_TEXTURE_SWIZZLE_G, NVN_TEXTURE_SWIZZLE_B, NVN_TEXTURE_SWIZZLE_A);
        EXPECT("out-of-range swizzle not stored", 0, w->set_swz);
    }

    // 3c. Texture description: SetSize2D / Swizzle / depth-stencil mode read back; an identity swizzle does not set swz_set (the replay layer builds no swizzle view)
    {
        NVNtextureBuilder tb2; P(nvnTextureBuilderSetDevice)(&tb2, &dev); P(nvnTextureBuilderSetDefaults)(&tb2);
        P(nvnTextureBuilderSetSize2D)(&tb2, 1920, 1080);
        EXPECT("SetSize2D width", 1920, P(nvnTextureBuilderGetWidth)(&tb2));
        EXPECT("SetSize2D height", 1080, P(nvnTextureBuilderGetHeight)(&tb2));
        EXPECT("SetSize2D depth = 1", 1, P(nvnTextureBuilderGetDepth)(&tb2));
        P(nvnTextureBuilderSetSwizzle)(&tb2, NVN_TEXTURE_SWIZZLE_R, NVN_TEXTURE_SWIZZLE_G, NVN_TEXTURE_SWIZZLE_B, NVN_TEXTURE_SWIZZLE_A);
        EXPECT("identity swizzle does not set swz_set", 0, ((tex_builder_t *)&tb2)->d.swz_set);
        P(nvnTextureBuilderSetSwizzle)(&tb2, NVN_TEXTURE_SWIZZLE_ONE, NVN_TEXTURE_SWIZZLE_ONE, NVN_TEXTURE_SWIZZLE_ONE, NVN_TEXTURE_SWIZZLE_R);
        NVNtextureSwizzle s0, s1, s2, s3; P(nvnTextureBuilderGetSwizzle)(&tb2, &s0, &s1, &s2, &s3);
        EXPECT("swizzle read back a = R", NVN_TEXTURE_SWIZZLE_R, s3);
        EXPECT("swizzle read back r = ONE", NVN_TEXTURE_SWIZZLE_ONE, s0);
        EXPECT("non-identity swizzle sets swz_set", 1, ((tex_builder_t *)&tb2)->d.swz_set);
        P(nvnTextureBuilderSetDepthStencilMode)(&tb2, NVN_TEXTURE_DEPTH_STENCIL_MODE_STENCIL);
        EXPECT("depth-stencil mode read back", NVN_TEXTURE_DEPTH_STENCIL_MODE_STENCIL, P(nvnTextureBuilderGetDepthStencilMode)(&tb2));
    }

    // 4. Texture storage size (block-linear: GOB = 64 B × 8 rows; block height from the GOB count of "height × 1.5": ≥16→16, ≥8→8 ...)
    //    256×256 RGBA8: 1024 B per row = 16 GOBs; height 256 rows = 32 GOB rows, block height 16 GOBs → 2 blocks; 16×2×(512×16) = 262144
    size_t al; EXPECT("256x256 RGBA8 size", 262144, tex_size(NVN_FORMAT_RGBA8, 256, 256, 0, &al));
    EXPECT("block-linear alignment", 512, al);
    //    100×100 RGBA8: 400 B → 7 GOBs wide; height 100 → 13 GOB rows, ×1.5 = 150 rows = 19 GOBs → block height 16 → 1 block; 7×1×8192 = 57344
    EXPECT("100x100 RGBA8 size", 57344, tex_size(NVN_FORMAT_RGBA8, 100, 100, 0, NULL));
    //    128×128 DXT1: 32×32 blocks, 8 B/block → 256 B = 4 GOBs wide; 32 rows → ×1.5 = 48 rows = 6 GOBs → block height 4 → 4 GOB rows = 1 block; 4×1×2048 = 8192
    EXPECT("128x128 DXT1 size", 8192, tex_size(NVN_FORMAT_RGBA_DXT1, 128, 128, 0, NULL));
    //    LINEAR 100×100 RGBA8: row pitch 400 aligned to 32 = 416; 416×100 = 41600, aligned to 32
    EXPECT("linear 100x100 RGBA8 size", 41600, tex_size(NVN_FORMAT_RGBA8, 100, 100, NVN_TEXTURE_FLAGS_LINEAR, &al));
    EXPECT("linear alignment", 32, al);

    // 5. Command buffer: record uniform updates / events / counters / buffer copies / nested calls, with memory in 256 B segments to force multi-segment linking
    NVNcommandBuffer cb; P(nvnCommandBufferInitialize)(&cb, &dev);
    NVNmemoryPoolBuilder cpb; P(nvnMemoryPoolBuilderSetDefaults)(&cpb); P(nvnMemoryPoolBuilderSetStorage)(&cpb, g_cmdmem, sizeof g_cmdmem);
    P(nvnMemoryPoolInitialize)(&g_cmdpool, &cpb);
    P(nvnCommandBufferSetMemoryCallback)(&cb, mem_cb); P(nvnCommandBufferSetMemoryCallbackData)(&cb, NULL);
    NVNeventBuilder eb; NVNevent ev; P(nvnEventBuilderSetDefaults)(&eb); P(nvnEventBuilderSetStorage)(&eb, &pool, 0x1000);
    P(nvnEventInitialize)(&ev, &eb);
    uint8_t *ub = poolmem + 0x2000, *cnt = poolmem + 0x3000, *src = poolmem + 0x4000, *dst = poolmem + 0x5000;
    for (int i = 0; i < 64; i++) src[i] = (uint8_t)(i * 3 + 1);
    uint32_t data[16];

    P(nvnCommandBufferBeginRecording)(&cb);
    EXPECT("recording", 1, P(nvnCommandBufferIsRecording)(&cb));
    for (int k = 0; k < 20; k++) {                        // 20 updates to different offsets of the same buffer, 64 B of data each
        for (int i = 0; i < 16; i++) data[i] = k * 100 + i;
        P(nvnCommandBufferUpdateUniformBuffer)(&cb, (NVNbufferAddress)ub, 4096, k * 64, 64, data);
        memset(data, 0xEE, sizeof data);                  // modify the original data after recording: the submit must use the values copied in at record time
    }
    P(nvnCommandBufferSignalEvent)(&cb, &ev, NVN_EVENT_SIGNAL_MODE_WRITE, NVN_EVENT_SIGNAL_LOCATION_BOTTOM, 0, 7);
    P(nvnCommandBufferSignalEvent)(&cb, &ev, NVN_EVENT_SIGNAL_MODE_ADD, NVN_EVENT_SIGNAL_LOCATION_BOTTOM, 0, 5);
    P(nvnCommandBufferReportCounter)(&cb, NVN_COUNTER_TYPE_TIMESTAMP, (NVNbufferAddress)cnt);
    NVNcommandHandle h1 = P(nvnCommandBufferEndRecording)(&cb);
    EXPECT("not recording after EndRecording", 0, P(nvnCommandBufferIsRecording)(&cb));
    P(nvnCommandBufferBeginRecording)(&cb);
    P(nvnCommandBufferCopyBufferToBuffer)(&cb, (NVNbufferAddress)src, (NVNbufferAddress)dst, 64, 0);
    P(nvnCommandBufferCopyCommands)(&cb, 1, &h1);         // nested: execute h1 once more (event 7 → +5 → write 7 again → +5)
    NVNcommandHandle h2 = P(nvnCommandBufferEndRecording)(&cb);
    printf("(command memory callback %d times, %zu B used)\n", g_cb_calls, g_cmdoff);
    EXPECT("command memory callback at least 2 times (multi-segment)", 1, g_cb_calls >= 2);
    EXPECT("event value still 0 before submit", 0, P(nvnEventGetValue)(&ev));

    NVNqueueBuilder qb; NVNqueue q; static uint8_t qmem[1 << 19];
    P(nvnQueueBuilderSetDevice)(&qb, &dev); P(nvnQueueBuilderSetDefaults)(&qb);
    size_t qsz = P(nvnQueueBuilderGetQueueMemorySize)(&qb);
    EXPECT("queue memory = 64K+256K+16K rounded to 4K", 65536 + 262144 + 16384, qsz);
    P(nvnQueueBuilderSetQueueMemory)(&qb, qmem, qsz);
    EXPECT("QueueInitialize succeeds", 1, P(nvnQueueInitialize)(&q, &qb));
    NVNcommandHandle hs[2] = {h1, h2};
    P(nvnQueueSubmitCommands)(&q, 2, hs);
    NVNsync sf; P(nvnSyncInitialize)(&sf, &dev); P(nvnQueueFenceSync)(&q, &sf, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
    int wr = P(nvnSyncWait)(&sf, 5000000000ull);
    EXPECT("fence wait after submit succeeds (0 or 1)", 1, wr == 0 || wr == 1);
    int ub_ok = 1;
    for (int k = 0; k < 20; k++) for (int i = 0; i < 16; i++) { uint32_t w; memcpy(&w, ub + k * 64 + i * 4, 4); ub_ok &= w == (uint32_t)(k * 100 + i); }
    EXPECT("uniform buffer 20×16 words all equal the recorded values", 1, ub_ok);
    EXPECT("event value: h1(7,+5), h2 copies then runs h1(7,+5) again = 12", 12, P(nvnEventGetValue)(&ev));
    EXPECT("buffer copy 64 B all equal", 0, memcmp(src, dst, 64));
    uint64_t ts[2]; memcpy(ts, cnt, 16);
    EXPECT("TIMESTAMP report: counter half 0, timestamp half non-zero (NVN: the counter value is always zero)", 1, ts[0] == 0 && ts[1] != 0);
    {   // Counter timestamps run on the guest clock (the system tick's base; here the weak default, mach_absolute_time): Tears of the Kingdom subtracts
        // its frame's start tick from the last report's timestamp. On CLOCK_MONOTONIC they were ahead by the Mac's total sleep time (25 hours here)
        uint64_t tns = P(nvnDeviceGetTimestampInNanoseconds)(&dev, (const NVNcounterData *)cnt), now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        uint64_t cur = P(nvnDeviceGetCurrentTimestampInNanoseconds)(&dev);
        EXPECT("TIMESTAMP report on the guest clock: written in the last 5 s, current timestamp on the same clock", 1,
               tns <= now + 1000 && now - tns < 5000000000ull && cur + 1000 >= now && cur - now < 1000000000ull);
    }

    {   // 5a. Command memory the way Tears of the Kingdom uses it: callback off, one 512-byte window per recording at slot + used of the previous one,
        // windows reaching into the next slots' recordings. Records are BIND_UBO (32 bytes) with distinct addresses; BEGIN and END take 8 each.
        static uint8_t cm[8192] __attribute__((aligned(4096))); NVNmemoryPoolBuilder cmb;
        P(nvnMemoryPoolBuilderSetDefaults)(&cmb); P(nvnMemoryPoolBuilderSetStorage)(&cmb, cm, sizeof cm); P(nvnMemoryPoolInitialize)(&g_tcpool, &cmb);
        P(nvnCommandBufferInitialize)(&g_tc, &dev);
        ((void (*)(NVNcommandBuffer *, unsigned))proc("nvnCommandBufferSetCommandMemoryCallbackEnabled"))(&g_tc, 0);
        // (1) The game's NVN 55 inline wrappers store a byte at cmd + 0x10 before every call (main 0xba70): it must not shorten the segment.
        //     8 + 14 x 32 + 8 = 464 bytes fit a 512-byte window with the 24 kept for a JUMP; as end's low byte (0x40 -> 0x01) it overflowed
        P(nvnCommandBufferAddCommandMemory)(&g_tc, &g_tcpool, 0x40, 512); ((uint8_t *)&g_tc)[0x10] = 1;
        NVNcommandHandle hd = rec_binds(-1, 14, 0x10000000ull);
        EXPECT("byte at cmd + 0x10: a 464-byte recording stays in its window", 1, !jump_of(hd, NULL) && binds_are(hd, 0x10000000ull, 14));
        EXPECT("... and GetCommandMemoryUsed reports 464", 464, P(nvnCommandBufferGetCommandMemoryUsed)(&g_tc));
        // (2) Only END left for the next segment: 8 + 15 x 32 = 488 leaves 24 bytes, END needs 8 + 24, so the JUMP takes bytes 488..504. Used must
        //     cover it: the game records the next slot at slot + used (496 before, and the next BEGIN overwrote the JUMP's target)
        const uint8_t *at = NULL;
        NVNcommandHandle hx = rec_binds(0x400, 15, 0x20000000ull);
        EXPECT("only END in a host segment: the JUMP is at byte 488", 488, jump_of(hx, &at) ? (long long)(at - (const uint8_t *)(uintptr_t)hx) : -1);
        EXPECT("... and used covers the JUMP (8 + 480 + 16 + 8)", 512, P(nvnCommandBufferGetCommandMemoryUsed)(&g_tc));
        // (3) A host segment stays while its JUMP does. A overflows at cm + 0x1200 (20 binds: 15 in the window, 5 and END in a host segment); B's window
        //     [cm + 0x1100, + 512) reaches into A but B writes 80 bytes; C overflows elsewhere and must not get A's segment (the window used to free it)
        NVNcommandHandle ha = rec_binds(0x1200, 20, 0x30000000ull);
        const uint8_t *seg_a = jump_of(ha, NULL);
        NVNcommandHandle hb = rec_binds(0x1100, 2, 0x40000000ull);
        NVNcommandHandle hc = rec_binds(0x1600, 20, 0x50000000ull);
        EXPECT("A overflowed into a host segment, B did not", 1, seg_a && !jump_of(hb, NULL));
        EXPECT("a later window reaching into A leaves A's host segment to A", 1, seg_a_linked(seg_a) == 1 && jump_of(hc, NULL) && jump_of(hc, NULL) != seg_a && binds_are(ha, 0x30000000ull, 20));
        // (4) Recording D over A's slot writes its own JUMP where A's was: A's segment is free then, and the next overflow (E) gets it
        NVNcommandHandle hdd = rec_binds(0x1200, 18, 0x60000000ull);
        EXPECT("D took another segment while A's JUMP was still there", 1, jump_of(hdd, NULL) && jump_of(hdd, NULL) != seg_a);
        EXPECT("A's segment is unlinked once D overwrote A's JUMP", 0, seg_a_linked(seg_a));
        NVNcommandHandle he = rec_binds(0x1a00, 20, 0x70000000ull);
        EXPECT("... and the next overflow reuses it", 1, jump_of(he, NULL) == seg_a && binds_are(he, 0x70000000ull, 20) && binds_are(hdd, 0x60000000ull, 18));
        P(nvnCommandBufferFinalize)(&g_tc); P(nvnMemoryPoolFinalize)(&g_tcpool);
    }

    // 5b. Sync must hold the CPU back: first queue 24 copies of 64 MiB to keep the GPU busy, with the last one copying src to dst;
    //     the CPU rewrites src only after the fence wait returns. If the wait is released early, that last copy reads the rewritten src.
    {
        size_t big = 64u << 20, pgsz = 16384;
        uint8_t *heap; posix_memalign((void **)&heap, pgsz, 4 * big);
        uint8_t *busy_a = heap, *busy_b = heap + big, *bsrc = heap + 2 * big, *bdst = heap + 3 * big;
        memset(heap, 0, 4 * big); memset(bsrc, 0x5A, big);
        NVNmemoryPoolBuilder hb; NVNmemoryPool hp; P(nvnMemoryPoolBuilderSetDefaults)(&hb); P(nvnMemoryPoolBuilderSetStorage)(&hb, heap, 4 * big);
        P(nvnMemoryPoolInitialize)(&hp, &hb);
        P(nvnCommandBufferBeginRecording)(&cb);
        for (int i = 0; i < 24; i++) P(nvnCommandBufferCopyBufferToBuffer)(&cb, (NVNbufferAddress)busy_a, (NVNbufferAddress)busy_b, big, 0);
        P(nvnCommandBufferCopyBufferToBuffer)(&cb, (NVNbufferAddress)bsrc, (NVNbufferAddress)bdst, big, 0);
        uint64_t *tsr = (uint64_t *)(busy_a + 4096); tsr[0] = tsr[1] = 0x1111111111111111ull;   // a TIMESTAMP report after the busy copies (inside the pool, not copied over)
        P(nvnCommandBufferReportCounter)(&cb, NVN_COUNTER_TYPE_TIMESTAMP, (NVNbufferAddress)tsr);
        NVNcommandHandle hb2 = P(nvnCommandBufferEndRecording)(&cb);
        NVNsync sb; P(nvnSyncInitialize)(&sb, &dev);
        uint64_t t0 = now_ns();
        P(nvnQueueSubmitCommands)(&q, 1, &hb2); P(nvnQueueFenceSync)(&q, &sb, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
        uint64_t ts_early = tsr[1], cnt_early = tsr[0];
        int w0 = P(nvnSyncWait)(&sb, 0);
        int w1 = P(nvnSyncWait)(&sb, 10000000000ull);
        double ms = (now_ns() - t0) / 1e6;
        memset(bsrc, 0xC3, big);                                       // rewrite only after the wait is released
        size_t bad = 0; for (size_t i = 0; i < big; i += 4096) bad += bdst[i] != 0x5A;
        printf("(GPU busy about %.1f ms)\n", ms);
        EXPECT("zero-timeout wait right after submit = timeout(2)", 2, w0);
        EXPECT("long wait = satisfied(1)", 1, w1);
        EXPECT("dst all pre-rewrite values (16384 places sampled)", 0, bad);
        // A report's timestamp appears only when the GPU has run it (Tears of the Kingdom read a timestamp written at replay as "the GPU is past
        // this point" and its frames alternated); its counter half is written in command order (conditional rendering compares it at replay)
        EXPECT("TIMESTAMP report while the GPU is busy: counter half 0, timestamp half not written yet", 1, cnt_early == 0 && ts_early == 0x1111111111111111ull);
        EXPECT("TIMESTAMP report after the wait: timestamp written", 1, tsr[1] != 0x1111111111111111ull);
        P(nvnMemoryPoolFinalize)(&hp); free(heap);
    }

    // 5c. Consecutive copies in one blit encoder must keep recording order: Metal 4 does not order the commands within one encoder, so reusing the
    //     encoder needs a barrier between copies (nvn_mtl.m blit()). Each round: A→D, B→D (two writes to one range: the later one must stay), D→E
    //     (write then read: must read B). 16 rounds of 16 MiB blocks back to back make a reorder likely (from upstream d2r-mobile)
    {
        size_t big = 16u << 20, pgsz = 16384; int rounds = 16;
        uint8_t *heap; posix_memalign((void **)&heap, pgsz, 4 * big);
        uint8_t *ba = heap, *bb = heap + big, *bd = heap + 2 * big, *be = heap + 3 * big;
        memset(ba, 0x11, big); memset(bb, 0x22, big); memset(bd, 0, big); memset(be, 0, big);
        NVNmemoryPoolBuilder hb; NVNmemoryPool hp; P(nvnMemoryPoolBuilderSetDefaults)(&hb); P(nvnMemoryPoolBuilderSetStorage)(&hb, heap, 4 * big);
        P(nvnMemoryPoolInitialize)(&hp, &hb);
        P(nvnCommandBufferBeginRecording)(&cb);
        for (int r = 0; r < rounds; r++) {
            P(nvnCommandBufferCopyBufferToBuffer)(&cb, (NVNbufferAddress)ba, (NVNbufferAddress)bd, big, 0);
            P(nvnCommandBufferCopyBufferToBuffer)(&cb, (NVNbufferAddress)bb, (NVNbufferAddress)bd, big, 0);
            P(nvnCommandBufferCopyBufferToBuffer)(&cb, (NVNbufferAddress)bd, (NVNbufferAddress)be, big, 0);
        }
        NVNcommandHandle hc = P(nvnCommandBufferEndRecording)(&cb);
        NVNsync sc; P(nvnSyncInitialize)(&sc, &dev);
        P(nvnQueueSubmitCommands)(&q, 1, &hc); P(nvnQueueFenceSync)(&q, &sc, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
        EXPECT("consecutive copies: wait satisfied after submit (1)", 1, P(nvnSyncWait)(&sc, 10000000000ull));
        size_t bad_d = 0, bad_e = 0; for (size_t i = 0; i < big; i += 4096) { bad_d += bd[i] != 0x22; bad_e += be[i] != 0x22; }
        EXPECT("two writes to one range: the later write B stays (4096 samples)", 0, bad_d);
        EXPECT("write then read: the read sees the later write B (4096 samples)", 0, bad_e);
        P(nvnMemoryPoolFinalize)(&hp); free(heap);
    }

    // 6. Sync / window / present
    NVNsync s1, s2; P(nvnSyncInitialize)(&s1, &dev); P(nvnSyncInitialize)(&s2, &dev);
    EXPECT("wait on unfenced sync = timeout(2)", 2, P(nvnSyncWait)(&s1, 0));
    P(nvnQueueFenceSync)(&q, &s1, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
    EXPECT("wait after fence = already signaled(0)", 0, P(nvnSyncWait)(&s1, 0));
    NVNtexture sc[2]; NVNtextureBuilder tb; P(nvnTextureBuilderSetDevice)(&tb, &dev); P(nvnTextureBuilderSetDefaults)(&tb);
    P(nvnTextureBuilderSetWidth)(&tb, 1280); P(nvnTextureBuilderSetHeight)(&tb, 720); P(nvnTextureBuilderSetFormat)(&tb, NVN_FORMAT_RGBA8);
    P(nvnTextureBuilderSetStorage)(&tb, &pool, 0); P(nvnTextureInitialize)(&sc[0], &tb); P(nvnTextureInitialize)(&sc[1], &tb);
    EXPECT("texture width", 1280, P(nvnTextureGetWidth)(&sc[0]));
    NVNtexture *scp[2] = {&sc[0], &sc[1]};
    NVNwindowBuilder wb; NVNwindow win; P(nvnWindowBuilderSetDevice)(&wb, &dev); P(nvnWindowBuilderSetDefaults)(&wb);
    P(nvnWindowBuilderSetTextures)(&wb, 2, scp); EXPECT("WindowInitialize succeeds", 1, P(nvnWindowInitialize)(&win, &wb));
    int idx[4];
    for (int f = 0; f < 4; f++) {
        P(nvnWindowAcquireTexture)(&win, &s2, &idx[f]);
        for (int b = 0; b < 5; b++) P(nvnCommandBufferBarrier)(&cb, 0);
        P(nvnQueuePresentTexture)(&q, &win, idx[f]);
    }
    EXPECT("swapchain rotation 0,1,0,1", 0x0101, idx[0] << 12 | idx[1] << 8 | idx[2] << 4 | idx[3]);
    EXPECT("sync after acquire already signaled(0)", 0, P(nvnSyncWait)(&s2, 0));
    unsigned bi = 0; while (strcmp(nvn_names[bi], "nvnCommandBufferBarrier")) bi++;
    EXPECT("Barrier count = 4 frames × 5", 20, nvn_slot[bi].cnt);

    // 6b. Readback: pixel (x,y) = {x*16+y, y*16+x, 0x55, 0xAA} (expected values computed directly from the formula)
    {
        #define PX(x, y, c) ((uint8_t)((c) == 0 ? (x) * 16 + (y) : (c) == 1 ? (y) * 16 + (x) : (c) == 2 ? 0x55 : 0xAA))
        static uint8_t rb[256 << 10] __attribute__((aligned(16384)));
        NVNmemoryPoolBuilder rpb; NVNmemoryPool rp; P(nvnMemoryPoolBuilderSetDefaults)(&rpb); P(nvnMemoryPoolBuilderSetStorage)(&rpb, rb, sizeof rb);
        P(nvnMemoryPoolInitialize)(&rp, &rpb);
        uint8_t *stage = rb + 0x8000, *outb = rb + 0xC000;
        for (int y = 0; y < 4; y++) for (int x = 0; x < 8; x++) for (int c = 0; c < 4; c++) stage[(y * 8 + x) * 4 + c] = PX(x, y, c);
        NVNtextureBuilder b; NVNtexture ta; P(nvnTextureBuilderSetDevice)(&b, &dev); P(nvnTextureBuilderSetDefaults)(&b);
        P(nvnTextureBuilderSetWidth)(&b, 8); P(nvnTextureBuilderSetHeight)(&b, 4); P(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8);
        P(nvnTextureBuilderSetStorage)(&b, &rp, 0); P(nvnTextureInitialize)(&ta, &b);
        NVNcopyRegion all = {0, 0, 0, 8, 4, 1}, sub = {2, 1, 0, 5, 3, 1}, cp = {1, 0, 0, 4, 2, 1};
        P(nvnCommandBufferBeginRecording)(&cb);
        P(nvnCommandBufferSetCopyRowStride)(&cb, 0);
        P(nvnCommandBufferCopyBufferToTexture)(&cb, (NVNbufferAddress)stage, &ta, NULL, &all, 0);
        P(nvnCommandBufferSetCopyRowStride)(&cb, 64);
        P(nvnCommandBufferCopyTextureToBuffer)(&cb, &ta, NULL, &cp, (NVNbufferAddress)outb, 0);
        NVNcommandHandle hr = P(nvnCommandBufferEndRecording)(&cb);
        memset(outb, 0xEE, 256);
        P(nvnQueueSubmitCommands)(&q, 1, &hr); P(nvnQueueFinish)(&q);
        uint8_t got[5 * 3 * 4]; P(nvnTextureReadTexels)(&ta, NULL, &sub, got);
        int bad = 0; for (int y = 0; y < 3; y++) for (int x = 0; x < 5; x++) for (int c = 0; c < 4; c++) bad += got[(y * 5 + x) * 4 + c] != PX(x + 2, y + 1, c);
        EXPECT("ReadTexels sub-region 5x3 byte for byte (texture written by the GPU)", 0, bad);
        uint8_t gs[4 * 40]; memset(gs, 0xEE, sizeof gs); P(nvnTextureReadTexelsStrided)(&ta, NULL, &all, gs, 40, 0);
        bad = 0; for (int y = 0; y < 4; y++) { for (int x = 0; x < 8; x++) for (int c = 0; c < 4; c++) bad += gs[y * 40 + x * 4 + c] != PX(x, y, c); for (int k = 32; k < 40; k++) bad += gs[y * 40 + k] != 0xEE; }
        EXPECT("ReadTexelsStrided row stride 40 (row-end padding untouched)", 0, bad);
        bad = 0; for (int y = 0; y < 2; y++) { for (int x = 0; x < 4; x++) for (int c = 0; c < 4; c++) bad += outb[y * 64 + x * 4 + c] != PX(x + 1, y, c); for (int k = 16; k < 64; k++) bad += outb[y * 64 + k] != 0xEE; }
        EXPECT("CopyTextureToBuffer row stride 64 (GPU copy-back)", 0, bad);
        // Packaged texture: the pool memory is the ground truth (block-linear); ReadTexels deswizzles and reads it directly
        uint8_t lin[16 * 8 * 4]; for (int y = 0; y < 8; y++) for (int x = 0; x < 16; x++) for (int c = 0; c < 4; c++) lin[(y * 16 + x) * 4 + c] = PX(x, y, c);
        NVNtexture tb; NVNpackagedTextureLayout lay = {{1, 0, 0, 0, 7, 0, 1, 0}};
        P(nvnTextureBuilderSetDefaults)(&b); P(nvnTextureBuilderSetWidth)(&b, 16); P(nvnTextureBuilderSetHeight)(&b, 8); P(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8);
        P(nvnTextureBuilderSetPackagedTextureLayout)(&b, &lay); P(nvnTextureBuilderSetStorage)(&b, &rp, 0x10000); P(nvnTextureInitialize)(&tb, &b);
        nvn_texdesc dd = ((tex_t *)&tb)->d;
        if (nvn_swizzle(&dd, 0, 0, lin, 64, rb + 0x10000)) { printf("nvn_swizzle failed\n"); g_fail++; }
        NVNcopyRegion s2 = {3, 2, 0, 9, 5, 1}; uint8_t g2[9 * 5 * 4];
        P(nvnTextureReadTexels)(&tb, NULL, &s2, g2);
        bad = 0; for (int y = 0; y < 5; y++) for (int x = 0; x < 9; x++) for (int c = 0; c < 4; c++) bad += g2[(y * 9 + x) * 4 + c] != PX(x + 3, y + 2, c);
        EXPECT("ReadTexels packaged texture 9x5 (direct block-linear read of pool memory)", 0, bad);
        P(nvnMemoryPoolFinalize)(&rp);
    }

    // 6b2. A texture finalized, and its object memory reused, after copies into and out of it were recorded and before they are submitted: NVN
    //      commands carry what they need in command memory, so the copies still use that texture; replay must not read the reused object (it used
    //      to: a garbage format at a scene load, a driver crash in a copy encoder). Its host copy is freed later, SNAP_KEEP submissions after release
    {
        static uint8_t fb[256 << 10] __attribute__((aligned(16384)));
        NVNmemoryPoolBuilder fpb; NVNmemoryPool fp; P(nvnMemoryPoolBuilderSetDefaults)(&fpb); P(nvnMemoryPoolBuilderSetStorage)(&fpb, fb, sizeof fb);
        P(nvnMemoryPoolInitialize)(&fp, &fpb);
        uint8_t *stage = fb + 0x8000, *outb = fb + 0xC000;
        for (int y = 0; y < 4; y++) for (int x = 0; x < 8; x++) for (int c = 0; c < 4; c++) stage[(y * 8 + x) * 4 + c] = PX(x, y, c) ^ 0x3C;
        NVNtextureBuilder b; NVNtexture tf; P(nvnTextureBuilderSetDevice)(&b, &dev); P(nvnTextureBuilderSetDefaults)(&b);
        P(nvnTextureBuilderSetWidth)(&b, 8); P(nvnTextureBuilderSetHeight)(&b, 4); P(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8);
        P(nvnTextureBuilderSetStorage)(&b, &fp, 0); P(nvnTextureInitialize)(&tf, &b);
        NVNcopyRegion all = {0, 0, 0, 8, 4, 1};
        P(nvnCommandBufferBeginRecording)(&cb); P(nvnCommandBufferSetCopyRowStride)(&cb, 0);
        P(nvnCommandBufferCopyBufferToTexture)(&cb, (NVNbufferAddress)stage, &tf, NULL, &all, 0);
        P(nvnCommandBufferCopyTextureToBuffer)(&cb, &tf, NULL, &all, (NVNbufferAddress)outb, 0);
        NVNcommandHandle hf = P(nvnCommandBufferEndRecording)(&cb);
        uint64_t snaps = mtl_tex_snap_count();
        P(nvnTextureFinalize)(&tf); memset(&tf, 0xA5, sizeof tf);   // the game finalizes the object and reuses its memory before submitting
        memset(outb, 0xEE, 128);
        P(nvnQueueSubmitCommands)(&q, 1, &hf); P(nvnQueueFinish)(&q);
        int bad = 0; for (int i = 0; i < 128; i++) bad += outb[i] != stage[i];
        EXPECT("copies recorded before the texture was finalized and its object reused: written and read back byte for byte", 0, bad);
        for (int i = 0; i < 640; i++) { P(nvnCommandBufferBeginRecording)(&cb); NVNcommandHandle he = P(nvnCommandBufferEndRecording)(&cb); P(nvnQueueSubmitCommands)(&q, 1, &he); }
        P(nvnQueueFinish)(&q);
        EXPECT("the texture's host copy is freed some submissions after its release", 1, (int)(snaps - mtl_tex_snap_count()) >= 1);
        P(nvnMemoryPoolFinalize)(&fp);
    }

    // 6c0. A small packaged texture (up to PKG_HASH_MAX, 4 KiB; 16x8 RGBA8 = 512 bytes) is checked by its content once per submission instead of by
    //      write-protecting its pages (pkg_hashed): a CPU write takes no page fault, and the next submission sees the new content
    {
        static uint8_t sb_[64 << 10] __attribute__((aligned(16384)));
        NVNmemoryPoolBuilder spb; NVNmemoryPool sp; P(nvnMemoryPoolBuilderSetDefaults)(&spb); P(nvnMemoryPoolBuilderSetStorage)(&spb, sb_, sizeof sb_);
        P(nvnMemoryPoolInitialize)(&sp, &spb);
        NVNtextureBuilder b; NVNtexture ts; NVNpackagedTextureLayout lay = {{1, 0, 0, 0, 7, 0, 1, 0}};
        P(nvnTextureBuilderSetDevice)(&b, &dev); P(nvnTextureBuilderSetDefaults)(&b); P(nvnTextureBuilderSetWidth)(&b, 16); P(nvnTextureBuilderSetHeight)(&b, 8);
        P(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8); P(nvnTextureBuilderSetPackagedTextureLayout)(&b, &lay);
        P(nvnTextureBuilderSetStorage)(&b, &sp, 0x4000); P(nvnTextureInitialize)(&ts, &b);
        nvn_texdesc dd = ((tex_t *)&ts)->d;
        uint8_t lin[16 * 8 * 4], *store = sb_ + 0x4000, *outb = sb_ + 0x8000;
        #define FILLS(k) for (int y = 0; y < 8; y++) for (int x = 0; x < 16; x++) for (int c = 0; c < 4; c++) lin[(y * 16 + x) * 4 + c] = (uint8_t)(x * 16 + y + (k) * 5 + c * 37)
        FILLS(0); nvn_swizzle(&dd, 0, 0, lin, 64, store);
        NVNcopyRegion all = {0, 0, 0, 16, 8, 1};
        #define GPU_READ_S(k, name) do { P(nvnCommandBufferBeginRecording)(&cb); P(nvnCommandBufferSetCopyRowStride)(&cb, 0); \
            P(nvnCommandBufferCopyTextureToBuffer)(&cb, &ts, NULL, &all, (NVNbufferAddress)outb, 0); NVNcommandHandle hh = P(nvnCommandBufferEndRecording)(&cb); \
            P(nvnQueueSubmitCommands)(&q, 1, &hh); P(nvnQueueFinish)(&q); FILLS(k); EXPECT(name, 0, memcmp(outb, lin, sizeof lin)); } while (0)
        uint64_t up0, re0, fa0, pr0, up, re, fa, pr; mtl_pkg_stats(&up0, &re0);
        GPU_READ_S(0, "small texture: first upload = version 0");
        nvn_dirty_stats(&fa0, &pr0);
        FILLS(1); nvn_swizzle(&dd, 0, 0, lin, 64, store);
        nvn_dirty_stats(&fa, &pr); EXPECT("small texture: a CPU write takes no page fault (not write-protected)", 0, fa - fa0);
        GPU_READ_S(1, "small texture: the next submission reads version 1 (content hash)");
        mtl_pkg_stats(&up, &re); EXPECT("small texture: one re-upload", 1, re - re0);
        GPU_READ_S(1, "small texture: unchanged, still version 1");
        mtl_pkg_stats(&up, &re); EXPECT("small texture: unchanged content, no re-upload", 1, re - re0);
        P(nvnMemoryPoolFinalize)(&sp);
        #undef FILLS
        #undef GPU_READ_S
    }

    // 6c. Write-protected dirty pages (a texture above PKG_HASH_MAX, 4 KiB: 64x32 RGBA8): after a packaged texture is uploaded its pool pages are read-only; game write → page fault → mark dirty → re-upload on next use; a direct host read() write needs prepare first
    {
        static uint8_t wb_[256 << 10] __attribute__((aligned(16384)));
        NVNmemoryPoolBuilder wpb; NVNmemoryPool wp; P(nvnMemoryPoolBuilderSetDefaults)(&wpb); P(nvnMemoryPoolBuilderSetStorage)(&wpb, wb_, sizeof wb_);
        P(nvnMemoryPoolInitialize)(&wp, &wpb);
        NVNtextureBuilder b; NVNtexture tw; NVNpackagedTextureLayout lay = {{1, 0, 0, 0, 7, 0, 1, 0}};
        P(nvnTextureBuilderSetDevice)(&b, &dev); P(nvnTextureBuilderSetDefaults)(&b); P(nvnTextureBuilderSetWidth)(&b, 64); P(nvnTextureBuilderSetHeight)(&b, 32);
        P(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8); P(nvnTextureBuilderSetPackagedTextureLayout)(&b, &lay);
        P(nvnTextureBuilderSetStorage)(&b, &wp, 0x10000); P(nvnTextureInitialize)(&tw, &b);
        nvn_texdesc dd = ((tex_t *)&tw)->d;
        uint8_t lin[64 * 32 * 4], *store = wb_ + 0x10000, *outb = wb_ + 0x20000;
        #define FILLPAT(k) for (int y = 0; y < 32; y++) for (int x = 0; x < 64; x++) for (int c = 0; c < 4; c++) lin[(y * 64 + x) * 4 + c] = (uint8_t)(x * 16 + y + (k) * 3 + c * 41)
        FILLPAT(0); nvn_swizzle(&dd, 0, 0, lin, 256, store);
        NVNcopyRegion all = {0, 0, 0, 64, 32, 1};
        // Check the actual GPU-side contents with a GPU copy-back (CopyTextureToBuffer reading the MTLTexture): expected = pattern version k
        #define GPU_READ_EQ(k, name) do { P(nvnCommandBufferBeginRecording)(&cb); P(nvnCommandBufferSetCopyRowStride)(&cb, 0); \
            P(nvnCommandBufferCopyTextureToBuffer)(&cb, &tw, NULL, &all, (NVNbufferAddress)outb, 0); NVNcommandHandle hh = P(nvnCommandBufferEndRecording)(&cb); \
            P(nvnQueueSubmitCommands)(&q, 1, &hh); P(nvnQueueFinish)(&q); FILLPAT(k); EXPECT(name, 0, memcmp(outb, lin, sizeof lin)); } while (0)
        uint64_t up0, re0, fa0, pr0, up, re, fa, pr; mtl_pkg_stats(&up0, &re0); nvn_dirty_stats(&fa0, &pr0);
        GPU_READ_EQ(0, "first upload: GPU-side contents = version 0");
        mtl_pkg_stats(&up, &re); EXPECT("first upload count +1", 1, up - up0);
        FILLPAT(1); nvn_swizzle(&dd, 0, 0, lin, 256, store);          // game-style CPU write: protected page → page fault → hook marks it dirty
        nvn_dirty_stats(&fa, &pr); EXPECT("game write triggers ≥ 1 page fault (caught by the hook, no crash)", 1, fa - fa0 >= 1);
        GPU_READ_EQ(1, "after re-upload GPU-side contents = version 1");
        mtl_pkg_stats(&up, &re); EXPECT("pool contents changed: re-upload +1", 1, re - re0);
        uint64_t fa1 = fa; GPU_READ_EQ(1, "reuse with unchanged contents: still version 1");
        nvn_dirty_stats(&fa, &pr); mtl_pkg_stats(&up, &re); EXPECT("contents unchanged: page faults +0", 0, fa - fa1); EXPECT("contents unchanged: re-uploads still 1", 1, re - re0);
        // Pitfall 1: host read() writing directly into protected pages. Without prepare the kernel returns EFAULT (no page fault); after prepare the read succeeds, the pages are marked dirty and re-uploaded next time
        char path[1024]; snprintf(path, sizeof path, "%s/t_nvn_rd_XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "."); int fd = mkstemp(path);   // per-user temp directory, do not write to /tmp
        FILLPAT(2); uint8_t tmpst[sizeof lin * 4]; memset(tmpst, 0, sizeof tmpst);
        static uint8_t full[0x10000]; memcpy(full, store, sizeof full);   // existing storage contents (block-linear); write version 2 into a copy and then save it to a file
        nvn_swizzle(&dd, 0, 0, lin, 256, full); if (write(fd, full, ((tex_t *)&tw)->size) < 0) g_fail++;
        ssize_t r0 = pread(fd, store, ((tex_t *)&tw)->size, 0); int e0 = errno;
        EXPECT("without prepare: read() into protected pages returns -1 and EFAULT", 1, r0 == -1 && e0 == EFAULT);
        dm_guest_write_prepare(store, ((tex_t *)&tw)->size);
        ssize_t r1 = pread(fd, store, ((tex_t *)&tw)->size, 0);
        EXPECT("read() succeeds after prepare", (long long)((tex_t *)&tw)->size, r1);
        close(fd); unlink(path);
        GPU_READ_EQ(2, "re-upload after host write: GPU-side contents = version 2");
        mtl_pkg_stats(&up, &re); EXPECT("host write triggers re-upload, total 2", 2, re - re0);
        P(nvnMemoryPoolFinalize)(&wp);
    }

    // 6c2. Conditional rendering: SetRenderEnableConditional compares the 64-bit values at counters and counters + 16; a TIMESTAMP_TOP report writes 0 into
    //      the counter half. Tears of the Kingdom clears its lighting buffers once per frame that way: conditional (not equal) clear, report into the same
    //      counters, and the next conditional clear of the frame is skipped. Then a RENDER_IF_EQUAL clear on equal values, and SetRenderEnable(false)
    {
        static uint8_t cm[256 << 10] __attribute__((aligned(16384)));
        NVNmemoryPoolBuilder cpb2; NVNmemoryPool cp2; P(nvnMemoryPoolBuilderSetDefaults)(&cpb2); P(nvnMemoryPoolBuilderSetStorage)(&cpb2, cm, sizeof cm);
        P(nvnMemoryPoolInitialize)(&cp2, &cpb2);
        uint64_t *X = (uint64_t *)(cm + 0x8000), *Y = (uint64_t *)(cm + 0x8100); X[0] = 1; X[1] = 0; X[2] = 0; X[3] = 0; Y[0] = 5; Y[1] = 0; Y[2] = 5; Y[3] = 0;
        NVNtextureBuilder b; NVNtexture tc, td; P(nvnTextureBuilderSetDevice)(&b, &dev); P(nvnTextureBuilderSetDefaults)(&b);
        P(nvnTextureBuilderSetWidth)(&b, 8); P(nvnTextureBuilderSetHeight)(&b, 4); P(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8);
        P(nvnTextureBuilderSetStorage)(&b, &cp2, 0); P(nvnTextureInitialize)(&tc, &b);
        P(nvnTextureBuilderSetStorage)(&b, &cp2, 0x4000); P(nvnTextureInitialize)(&td, &b);
        const float red[4] = {1, 0, 0, 1}, green[4] = {0, 1, 0, 1}, blue[4] = {0, 0, 1, 1}, white[4] = {1, 1, 1, 1};
        const NVNtexture *rt1[1] = {&tc}, *rt2[1] = {&td};
        P(nvnCommandBufferBeginRecording)(&cb);
        P(nvnCommandBufferSetRenderTargets)(&cb, 1, rt1, NULL, NULL, NULL);
        P(nvnCommandBufferSetRenderEnableConditional)(&cb, NVN_CONDITIONAL_RENDER_MODE_RENDER_IF_NOT_EQUAL, (NVNbufferAddress)X);
        P(nvnCommandBufferClearColor)(&cb, 0, red, NVN_CLEAR_COLOR_MASK_RGBA);                     // X[0] 1 ≠ X[2] 0: cleared
        P(nvnCommandBufferReportCounter)(&cb, NVN_COUNTER_TYPE_TIMESTAMP_TOP, (NVNbufferAddress)X);
        P(nvnCommandBufferSetRenderEnable)(&cb, 1);
        P(nvnCommandBufferSetRenderEnableConditional)(&cb, NVN_CONDITIONAL_RENDER_MODE_RENDER_IF_NOT_EQUAL, (NVNbufferAddress)X);
        P(nvnCommandBufferClearColor)(&cb, 0, green, NVN_CLEAR_COLOR_MASK_RGBA);                   // X[0] 0 = X[2] 0: skipped
        P(nvnCommandBufferReportCounter)(&cb, NVN_COUNTER_TYPE_TIMESTAMP_TOP, (NVNbufferAddress)X);
        P(nvnCommandBufferSetRenderEnable)(&cb, 1);
        P(nvnCommandBufferSetRenderTargets)(&cb, 1, rt2, NULL, NULL, NULL);
        P(nvnCommandBufferSetRenderEnableConditional)(&cb, NVN_CONDITIONAL_RENDER_MODE_RENDER_IF_EQUAL, (NVNbufferAddress)Y);
        P(nvnCommandBufferClearColor)(&cb, 0, blue, NVN_CLEAR_COLOR_MASK_RGBA);                    // Y[0] 5 = Y[2] 5: cleared
        P(nvnCommandBufferSetRenderEnable)(&cb, 0);
        P(nvnCommandBufferClearColor)(&cb, 0, white, NVN_CLEAR_COLOR_MASK_RGBA);                   // rendering off: discarded
        P(nvnCommandBufferSetRenderEnable)(&cb, 1);
        NVNcommandHandle hc = P(nvnCommandBufferEndRecording)(&cb);
        P(nvnQueueSubmitCommands)(&q, 1, &hc); P(nvnQueueFinish)(&q);
        NVNcopyRegion all = {0, 0, 0, 8, 4, 1}; uint8_t g1[8 * 4 * 4], g2[8 * 4 * 4];
        P(nvnTextureReadTexels)(&tc, NULL, &all, g1); P(nvnTextureReadTexels)(&td, NULL, &all, g2);
        int bad1 = 0, bad2 = 0; for (int i = 0; i < 32; i++) { bad1 += g1[i * 4] != 255 || g1[i * 4 + 1] != 0 || g1[i * 4 + 2] != 0; bad2 += g2[i * 4] != 0 || g2[i * 4 + 1] != 0 || g2[i * 4 + 2] != 255; }
        EXPECT("conditional clear once: the first (not equal) clear ran, the second was skipped (red)", 0, bad1);
        EXPECT("RENDER_IF_EQUAL on equal values cleared, the clear with rendering off was discarded (blue)", 0, bad2);
        EXPECT("TIMESTAMP_TOP report wrote 0 into the counter half", 0, (long long)X[0]);
        P(nvnTextureFinalize)(&tc); P(nvnTextureFinalize)(&td); P(nvnMemoryPoolFinalize)(&cp2);
    }

    // 6c2b. A conditional on a samples-passed result still on the GPU renders, however many reports are in flight: 300 reports after the one the
    //       conditional reads (the 256-entry ring had dropped it, its stale "equal" values were read and the clear was skipped). The submission with
    //       the reports is kept busy by big copies
    {
        size_t big = 64u << 20, pgsz = 16384;
        uint8_t *heap; posix_memalign((void **)&heap, pgsz, 2 * big + (1 << 20));
        memset(heap, 0, 2 * big + (1 << 20));
        uint8_t *busy_a = heap, *busy_b = heap + big, *small = heap + 2 * big;
        NVNmemoryPoolBuilder ob; NVNmemoryPool op; P(nvnMemoryPoolBuilderSetDefaults)(&ob); P(nvnMemoryPoolBuilderSetStorage)(&ob, heap, 2 * big + (1 << 20));
        P(nvnMemoryPoolInitialize)(&op, &ob);
        uint64_t *X = (uint64_t *)(small + 0x80000); X[0] = 7; X[1] = 0; X[2] = 7; X[3] = 0;   // a previous frame's result: equal
        NVNtextureBuilder b; NVNtexture tc; P(nvnTextureBuilderSetDevice)(&b, &dev); P(nvnTextureBuilderSetDefaults)(&b);
        P(nvnTextureBuilderSetWidth)(&b, 8); P(nvnTextureBuilderSetHeight)(&b, 4); P(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8);
        P(nvnTextureBuilderSetStorage)(&b, &op, 2 * big); P(nvnTextureInitialize)(&tc, &b);
        const float red[4] = {1, 0, 0, 1}; const NVNtexture *rt[1] = {&tc};
        P(nvnCommandBufferBeginRecording)(&cb);
        for (int i = 0; i < 24; i++) P(nvnCommandBufferCopyBufferToBuffer)(&cb, (NVNbufferAddress)busy_a, (NVNbufferAddress)busy_b, big, 0);
        P(nvnCommandBufferResetCounter)(&cb, NVN_COUNTER_TYPE_SAMPLES_PASSED);
        P(nvnCommandBufferReportCounter)(&cb, NVN_COUNTER_TYPE_SAMPLES_PASSED, (NVNbufferAddress)X);
        for (int i = 0; i < 300; i++) P(nvnCommandBufferReportCounter)(&cb, NVN_COUNTER_TYPE_SAMPLES_PASSED, (NVNbufferAddress)(small + 0x1000 + 32 * i));
        NVNcommandHandle h1 = P(nvnCommandBufferEndRecording)(&cb);
        P(nvnCommandBufferBeginRecording)(&cb);
        P(nvnCommandBufferSetRenderTargets)(&cb, 1, rt, NULL, NULL, NULL);
        P(nvnCommandBufferSetRenderEnableConditional)(&cb, NVN_CONDITIONAL_RENDER_MODE_RENDER_IF_NOT_EQUAL, (NVNbufferAddress)X);
        P(nvnCommandBufferClearColor)(&cb, 0, red, NVN_CLEAR_COLOR_MASK_RGBA);   // the result at X is still pending: rendering stays enabled
        P(nvnCommandBufferSetRenderEnable)(&cb, 1);
        NVNcommandHandle h2 = P(nvnCommandBufferEndRecording)(&cb);
        NVNsync s1; P(nvnSyncInitialize)(&s1, &dev);
        P(nvnQueueSubmitCommands)(&q, 1, &h1); P(nvnQueueFenceSync)(&q, &s1, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
        P(nvnQueueSubmitCommands)(&q, 1, &h2); P(nvnQueueFlush)(&q);
        int busy = P(nvnSyncWait)(&s1, 0) == 2;
        P(nvnQueueFinish)(&q);
        NVNcopyRegion all = {0, 0, 0, 8, 4, 1}; uint8_t g[8 * 4 * 4]; P(nvnTextureReadTexels)(&tc, NULL, &all, g);
        int bad = 0; for (int i = 0; i < 32; i++) bad += g[i * 4] != 255 || g[i * 4 + 1] != 0 || g[i * 4 + 2] != 0;
        EXPECT("the reports' submission was still on the GPU when the conditional was submitted", 1, busy);
        EXPECT("conditional on a pending samples-passed result with 300 reports after it: rendered (red)", 0, bad);
        EXPECT("the samples-passed result reached X once the GPU finished (nothing drawn: 0)", 0, (long long)X[0]);
        P(nvnTextureFinalize)(&tc); P(nvnMemoryPoolFinalize)(&op); free(heap);
    }

    // 6c3. Clears a load action cannot do: a scissored colour clear, a channel-masked clear, a scissored depth clear and one with a partial stencil
    //      mask (drawn as a triangle, nvn_mtl.m clear_quad / clear_ds_quad); they had been dropped, and the depth one had cleared the whole plane
    {
        static uint8_t qm[256 << 10] __attribute__((aligned(16384)));
        NVNmemoryPoolBuilder qpb; NVNmemoryPool qp; P(nvnMemoryPoolBuilderSetDefaults)(&qpb); P(nvnMemoryPoolBuilderSetStorage)(&qpb, qm, sizeof qm);
        P(nvnMemoryPoolInitialize)(&qp, &qpb);
        NVNtextureBuilder b; NVNtexture tc, tz; P(nvnTextureBuilderSetDevice)(&b, &dev); P(nvnTextureBuilderSetDefaults)(&b);
        P(nvnTextureBuilderSetWidth)(&b, 8); P(nvnTextureBuilderSetHeight)(&b, 4); P(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8);
        P(nvnTextureBuilderSetStorage)(&b, &qp, 0); P(nvnTextureInitialize)(&tc, &b);
        P(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_DEPTH24_STENCIL8); P(nvnTextureBuilderSetStorage)(&b, &qp, 0x10000); P(nvnTextureInitialize)(&tz, &b);
        const float red[4] = {1, 0, 0, 1}, green[4] = {0, 1, 0, 1}, blue[4] = {0, 0, 1, 1};
        const NVNtexture *rt[1] = {&tc};
        P(nvnCommandBufferBeginRecording)(&cb);
        P(nvnCommandBufferSetRenderTargets)(&cb, 1, rt, NULL, &tz, NULL);
        P(nvnCommandBufferSetScissor)(&cb, 0, 0, 8, 4);
        P(nvnCommandBufferClearColor)(&cb, 0, red, NVN_CLEAR_COLOR_MASK_RGBA);
        P(nvnCommandBufferClearDepthStencil)(&cb, 1.0f, 1, 0x0f, 0xff);
        P(nvnCommandBufferSetScissor)(&cb, 0, 0, 4, 2);
        P(nvnCommandBufferClearColor)(&cb, 0, green, NVN_CLEAR_COLOR_MASK_RGBA);                   // top left 4x2 only
        P(nvnCommandBufferClearDepthStencil)(&cb, 0.25f, 1, 0, 0);                                // depth of the top left 4x2 only
        P(nvnCommandBufferSetScissor)(&cb, 0, 0, 8, 4);
        P(nvnCommandBufferClearColor)(&cb, 0, blue, NVN_CLEAR_COLOR_MASK_B_BIT);                  // blue channel only, everywhere
        P(nvnCommandBufferClearDepthStencil)(&cb, 0.0f, 0, 0xf0, 0x30);                           // stencil bits 4-5 only: depth untouched
        NVNcommandHandle hq = P(nvnCommandBufferEndRecording)(&cb);
        P(nvnQueueSubmitCommands)(&q, 1, &hq); P(nvnQueueFinish)(&q);
        NVNcopyRegion all = {0, 0, 0, 8, 4, 1}; uint8_t g[8 * 4 * 4]; float z[8 * 4];
        P(nvnTextureReadTexels)(&tc, NULL, &all, g); P(nvnTextureReadTexels)(&tz, NULL, &all, z);   // a GPU-written depth-stencil texture reads back its depth as float (Depth32Float_Stencil8); stencil is not readable here
        int badc = 0, badz = 0;
        for (int y = 0; y < 4; y++) for (int x = 0; x < 8; x++) { int i = y * 8 + x, in = x < 4 && y < 2;
            badc += g[i * 4] != (in ? 0 : 255) || g[i * 4 + 1] != (in ? 255 : 0) || g[i * 4 + 2] != 255;
            badz += z[i] != (in ? 0.25f : 1.0f); }
        EXPECT("scissored colour clear: green only in the top left 4x2; blue-channel clear: B = 255 everywhere, R / G kept", 0, badc);
        EXPECT("scissored depth clear: 0.25 only in the top left 4x2, 1.0 elsewhere; the stencil-only clear left depth alone", 0, badz);
        // The same texture at two colour slots is attached once (rt_dup_slot): a scissored clear of the slot left out reaches the texture through the
        // slot kept (seedds/nxnative 7dde056, MIT; it was dropped with red line 75)
        const NVNtexture *rt2[2] = {&tc, &tc};
        P(nvnCommandBufferBeginRecording)(&cb);
        P(nvnCommandBufferSetRenderTargets)(&cb, 2, rt2, NULL, NULL, NULL);
        P(nvnCommandBufferSetScissor)(&cb, 0, 0, 8, 4);
        P(nvnCommandBufferClearColor)(&cb, 0, red, NVN_CLEAR_COLOR_MASK_RGBA);
        P(nvnCommandBufferSetScissor)(&cb, 4, 2, 4, 2);
        P(nvnCommandBufferClearColor)(&cb, 1, blue, NVN_CLEAR_COLOR_MASK_RGBA);                   // through slot 1, bottom right 4x2 only
        NVNcommandHandle hd = P(nvnCommandBufferEndRecording)(&cb);
        P(nvnQueueSubmitCommands)(&q, 1, &hd); P(nvnQueueFinish)(&q);
        P(nvnTextureReadTexels)(&tc, NULL, &all, g);
        int badd = 0;
        for (int y = 0; y < 4; y++) for (int x = 0; x < 8; x++) { int i = y * 8 + x, in = x >= 4 && y >= 2; badd += g[i * 4] != (in ? 0 : 255) || g[i * 4 + 2] != (in ? 255 : 0); }
        EXPECT("texture at two slots: the scissored clear of slot 1 lands in the bottom right 4x2", 0, badd);
        P(nvnTextureFinalize)(&tc); P(nvnTextureFinalize)(&tz); P(nvnMemoryPoolFinalize)(&qp);
    }

    // 6c4. A BC4 texture as a render target through an RGBA16UI view (one texel = one 8-byte block, as Tears of the Kingdom encodes BC4 on the GPU): the pass
    //      draws into an auxiliary texture and the blocks land in the BC4 texture (nvn_mtl.m blk_aux); the attachment used to be left out
    {
        static uint8_t bm[64 << 10] __attribute__((aligned(16384)));
        NVNmemoryPoolBuilder bpb; NVNmemoryPool bp; P(nvnMemoryPoolBuilderSetDefaults)(&bpb); P(nvnMemoryPoolBuilderSetStorage)(&bpb, bm, sizeof bm);
        P(nvnMemoryPoolInitialize)(&bp, &bpb);
        NVNtextureBuilder b; NVNtexture t4; P(nvnTextureBuilderSetDevice)(&b, &dev); P(nvnTextureBuilderSetDefaults)(&b);
        P(nvnTextureBuilderSetWidth)(&b, 8); P(nvnTextureBuilderSetHeight)(&b, 8); P(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGTC1_UNORM);
        P(nvnTextureBuilderSetStorage)(&b, &bp, 0); P(nvnTextureInitialize)(&t4, &b);
        NVNtextureView vw; P(nvnTextureViewSetDefaults)(&vw); P(nvnTextureViewSetFormat)(&vw, NVN_FORMAT_RGBA16UI);
        const NVNtexture *rt[1] = {&t4}; const NVNtextureView *rv[1] = {&vw};
        const float blk[4] = {0x1234, 0x5678, 0x9abc, 0xdef0};   // the 8 bytes of every block: 34 12 78 56 bc 9a f0 de
        P(nvnCommandBufferBeginRecording)(&cb);
        P(nvnCommandBufferSetRenderTargets)(&cb, 1, rt, rv, NULL, NULL);
        P(nvnCommandBufferSetScissor)(&cb, 0, 0, 8, 8);
        P(nvnCommandBufferClearColor)(&cb, 0, blk, NVN_CLEAR_COLOR_MASK_RGBA);
        NVNcommandHandle hb = P(nvnCommandBufferEndRecording)(&cb);
        P(nvnQueueSubmitCommands)(&q, 1, &hb); P(nvnQueueFinish)(&q);
        NVNcopyRegion all = {0, 0, 0, 8, 8, 1}; uint8_t g[2 * 2 * 8]; memset(g, 0, sizeof g);
        P(nvnTextureReadTexels)(&t4, NULL, &all, g);
        static const uint8_t want[8] = {0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a, 0xf0, 0xde}; int bad = 0;
        for (int k = 0; k < 4; k++) bad += memcmp(g + 8 * k, want, 8) != 0;
        EXPECT("BC4 render target through an RGBA16UI view: all 4 blocks hold the cleared 8 bytes", 0, bad);
        P(nvnTextureFinalize)(&t4); P(nvnMemoryPoolFinalize)(&bp);
    }

    // 6d. Lifecycle: in-flight GPU work is 0 when suspend returns; submits are blocked during suspend and let through after resume
    {
        size_t big = 64u << 20; uint8_t *heap; posix_memalign((void **)&heap, 16384, 2 * big); memset(heap, 0, 2 * big);
        NVNmemoryPoolBuilder hb; NVNmemoryPool hp; P(nvnMemoryPoolBuilderSetDefaults)(&hb); P(nvnMemoryPoolBuilderSetStorage)(&hb, heap, 2 * big);
        P(nvnMemoryPoolInitialize)(&hp, &hb);
        P(nvnCommandBufferBeginRecording)(&cb);
        for (int i = 0; i < 24; i++) P(nvnCommandBufferCopyBufferToBuffer)(&cb, (NVNbufferAddress)heap, (NVNbufferAddress)(heap + big), big, 0);
        NVNcommandHandle hbusy = P(nvnCommandBufferEndRecording)(&cb);
        P(nvnQueueSubmitCommands)(&q, 1, &hbusy);
        uint64_t f = mtl_last_fence();
        int busy_before = !mtl_wait(f, 0);
        dm_gfx_suspend(1);
        EXPECT("GPU really busy before suspend (zero-timeout wait not complete)", 1, busy_before);
        EXPECT("in-flight work complete when suspend returns", 1, mtl_wait(f, 0));
        P(nvnCommandBufferBeginRecording)(&cb); P(nvnCommandBufferBarrier)(&cb, 0); NVNcommandHandle hsmall = P(nvnCommandBufferEndRecording)(&cb);
        g_sq = &q; g_sh = hsmall; g_sub = P(nvnQueueSubmitCommands); atomic_store(&g_sstarted, 0); atomic_store(&g_sdone, 0);
        pthread_t th; pthread_create(&th, NULL, susp_thr, NULL);
        int started = wait_started();
        EXPECT("during suspend another thread has entered submit and not yet returned", 1, started && !atomic_load(&g_sdone));
        dm_gfx_suspend(0);
        pthread_join(th, NULL);
        EXPECT("after resume that submit is let through and returns", 1, atomic_load(&g_sdone));
        P(nvnQueueFinish)(&q); P(nvnMemoryPoolFinalize)(&hp); free(heap);
    }

    // 6e. Present pacing (real-device semantics): present returns immediately; blocking happens at acquire - swapchain of 3, interval 1, 60 Hz, the 4th acquire waits until texture 0 has been displayed for a full period
    {
        nvn_present_config(60, 0);
        NVNwindowBuilder wb2; NVNwindow w2; P(nvnWindowBuilderSetDevice)(&wb2, &dev); P(nvnWindowBuilderSetDefaults)(&wb2);
        NVNtexture *sc3[3] = {&sc[0], &sc[1], &sc[0]};
        P(nvnWindowBuilderSetTextures)(&wb2, 3, sc3); P(nvnWindowInitialize)(&w2, &wb2); P(nvnWindowSetPresentInterval)(&w2, 1);
        int ix;
        for (int k = 0; k < 3; k++) {
            P(nvnWindowAcquireTexture)(&w2, NULL, &ix);
            P(nvnQueuePresentTexture)(&q, &w2, ix);
        }
        P(nvnWindowAcquireTexture)(&w2, NULL, &ix);
        EXPECT("4th acquire gets texture 0", 0, ix);
        P(nvnQueuePresentTexture)(&q, &w2, ix);
        P(nvnWindowAcquireTexture)(&w2, NULL, &ix);
        EXPECT("5th acquire gets texture 1", 1, ix);
        nvn_present_config(0, 0);
    }

    // 6f. Present thread: when the drawable stays unavailable for a long time (the present thread stalls 200 ms each time), the present call still returns immediately;
    //     after the swapchain has gone a full round, re-acquiring texture 0 has to wait until its present has been processed (first enqueue + 200 ms)
    {
        nvn_present_config(0, 0);   // do not wait on the display link; only check that the present thread hands it back
        const double S = 200;
        mtl_present_test_stall((uint64_t)(S * 1e6));
        NVNwindowBuilder wb3; NVNwindow w3; P(nvnWindowBuilderSetDevice)(&wb3, &dev); P(nvnWindowBuilderSetDefaults)(&wb3);
        NVNtexture *sc3[3] = {&sc[0], &sc[1], &sc[0]};
        P(nvnWindowBuilderSetTextures)(&wb3, 3, sc3); P(nvnWindowInitialize)(&w3, &wb3);
        int ix;
        for (int k = 0; k < 3; k++) {
            P(nvnWindowAcquireTexture)(&w3, NULL, &ix);
            P(nvnQueuePresentTexture)(&q, &w3, ix);
        }
        P(nvnWindowAcquireTexture)(&w3, NULL, &ix);
        EXPECT("acquire gets texture 0", 0, ix);
        // nvnQueueFinish waits for the submitted GPU work, not for queued presents to be shown (seedds/nxnative 3b72aea, MIT: Fire Emblem: Three
        // Houses calls it after every resource upload, and its first load took 78 s on an iPhone): with presents still queued behind the stall
        P(nvnQueuePresentTexture)(&q, &w3, ix);
        uint64_t f0 = now_ns(); P(nvnQueueFinish)(&q); double fin_ms = (now_ns() - f0) / 1e6;
        EXPECT("QueueFinish with presents queued returns without waiting for them (< 100 ms)", 1, fin_ms < 100);
        mtl_present_test_stall(0); mtl_present_flush();
    }

    // 6b. Shader key = sha256(0x880-byte control section + code area of the length at control +0x704)[:8]: a shader with the same control
    //     section and other code gets another key (Tears of the Kingdom's bloom upsampler shared its control section with another shader and ran
    //     that one's code); bytes after the code area do not count
    {
        static uint8_t ctl[0x880], code_a[0x300], code_b[0x300], code_c[0x300];
        ctl[0] = 0x34; ctl[1] = 0x12; ctl[2] = 0x76; ctl[3] = 0x98; uint32_t len = 0x200; memcpy(ctl + 0x704, &len, 4);
        for (int i = 0; i < 0x300; i++) code_a[i] = (uint8_t)(i * 7);
        uint32_t magic = 0x12345678, sph = 2 | 5u << 10; memcpy(code_a, &magic, 4); memcpy(code_a + 0x30, &sph, 4);   // graphics code area, pixel shader
        memcpy(code_b, code_a, sizeof code_b); code_b[0x100] ^= 1;   // differs inside the code area
        memcpy(code_c, code_a, sizeof code_c); code_c[0x250] ^= 1;   // differs only after it
        NVNprogram pa, pb, pc;
        NVNshaderData sa = {(NVNbufferAddress)(uintptr_t)code_a, ctl}, sb = {(NVNbufferAddress)(uintptr_t)code_b, ctl}, sc = {(NVNbufferAddress)(uintptr_t)code_c, ctl};
        P(nvnProgramInitialize)(&pa, &dev); P(nvnProgramInitialize)(&pb, &dev); P(nvnProgramInitialize)(&pc, &dev);
        EXPECT("SetShaders accepted", 3, P(nvnProgramSetShaders)(&pa, 1, &sa) + P(nvnProgramSetShaders)(&pb, 1, &sb) + P(nvnProgramSetShaders)(&pc, 1, &sc));
        const prog_t *a = (const prog_t *)&pa, *b = (const prog_t *)&pb, *c = (const prog_t *)&pc;
        uint8_t want[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_CTX h; CC_SHA256_Init(&h); CC_SHA256_Update(&h, ctl, 0x880); CC_SHA256_Update(&h, code_a, 0x200); CC_SHA256_Final(want, &h);
        EXPECT("shader key = sha256(control + code area)[:8]", 0, memcmp(a->key[0], want, 8));
        EXPECT("same control section, other code: other key", 1, memcmp(a->key[0], b->key[0], 8) != 0);
        EXPECT("bytes after the code area do not count", 0, memcmp(a->key[0], c->key[0], 8));
        EXPECT("stage read from the code area: pixel", 1, a->kstage[0]);
        P(nvnProgramFinalize)(&pa); P(nvnProgramFinalize)(&pb); P(nvnProgramFinalize)(&pc);
    }

    // 7. Unimplemented functions: return 0, report a failure, report only once
    // Take the first name in the table that is still wired to the unimplemented stub and has not been called yet (implementations are filled in over time, so no name is hard-coded)
    unsigned ui = 0; while (ui < NVN_NFUNC && (nvn_slot[ui].fn != (void *)nvn_unimpl_entry || nvn_slot[ui].cnt)) ui++;
    EXPECT("name table still has unimplemented functions", 1, ui < NVN_NFUNC);
    if (ui < NVN_NFUNC) { ((void (*)(void *))proc(nvn_names[ui]))(NULL); ((void (*)(void *))proc(nvn_names[ui]))(NULL); }
    EXPECT("unimplemented function recorded as reported red after being called", 1, g_unimpl_seen[ui] > 0);
    EXPECT("unimplemented function count 2", 2, nvn_slot[ui].cnt);

    // 7b. Functions that used to be silent no-ops report on first call now, and so do the other indirect draws (plan item 60: implemented when a game
    // calls them; none has in the logs so far, and this line is how a game that does shows up); depth bounds report only when enabled
    { static const char *const red[] = {"nvnCommandBufferSetPatchSize", "nvnCommandBufferMultiDrawArraysIndirectCount", "nvnCommandBufferMultiDrawElementsIndirectCount",
                                        "nvnCommandBufferDispatchComputeIndirect", "nvnCommandBufferDownsampleTextureView",
                                        "nvnCommandBufferDrawArraysIndirect", "nvnCommandBufferDrawElementsIndirect"};
      int wired = 0; for (unsigned k = 0; k < sizeof red / sizeof *red; k++) { unsigned i = 0; while (i < NVN_NFUNC && strcmp(nvn_names[i], red[k])) i++; wired += i < NVN_NFUNC && nvn_slot[i].fn == (void *)nvn_unimpl_entry; }
      EXPECT("7b. the five former silent no-ops and the two indirect draws go to the red-reporting stub", 7, wired);
      P(nvnCommandBufferSetDepthBounds)(NULL, 0, 0.f, 1.f); EXPECT("7b. depth bounds disabled: no report", 0, g_depth_bounds_red);
      P(nvnCommandBufferSetDepthBounds)(NULL, 1, 0.25f, 0.75f); EXPECT("7b. depth bounds enabled: reported", 1, g_depth_bounds_red > 0); }

    printf("== %d checks, %d failed ==\n", g_n, g_fail);
    return g_fail != 0;
}
