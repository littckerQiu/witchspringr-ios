// Pooled upload staging blocks (nvn_mtl.m up_pool_take; MacNativeGames): upload batches one after another reuse the resident blocks once the earlier
// batch has completed, at most UP_POOL are made, and what is uploaded through a reused block is right. The census of the uploaded textures by last use
// (DM_NVN_COUNTS, plan item 56): 500 submissions later, one of the twelve used again: it in the first bucket, the eleven others in 301-1800.
// Negative control: -DDM_TEST_PKG_AGE_FIRST (a later use not noted) puts all twelve in 301-1800.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, want, got) do { long long w=(want), g=(got); count++; printf("%-70s expected %-10llx → got %-10llx %s\n", name, (unsigned long long)w, (unsigned long long)g, w==g?"✓":"✗"); fail += w != g; } while (0)
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); setenv("DM_NVN_COUNTS", "1", 1); mtl_init();
    uint8_t *mem; if (posix_memalign((void **)&mem, getpagesize(), 8 << 20)) abort(); memset(mem, 0, 8 << 20); mtl_pool_add(mem, 8 << 20); nvn_dirty_add_range(mem, 8 << 20);
    static pool_t pl; pl.mem = mem; pl.size = 8 << 20; pl.flags = NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED;
    uint32_t last = 0; tex_t t;
    for (int k = 0; k < 12; k++) {   // twelve batches, each one CPU-filled texture uploaded at its first use
        t = (tex_t){.serial = 9700 + (uint64_t)k}; t.d.width = t.d.height = 64; t.d.depth = t.d.samples = t.d.levels = 1; t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = NVN_FORMAT_RGBA8;
        nvn_texlayout L; nvn_tex_layout(&t.d, &L); t.size = (uint32_t)L.size; t.mem = mem + (size_t)k * 0x10000; t.pool = &pl;
        uint32_t lin[64 * 64]; for (int i = 0; i < 64 * 64; i++) lin[i] = last = 0x01020300u + (uint32_t)k; nvn_swizzle(&t.d, 0, 0, lin, 256, t.mem);
        mtl_sub_begin(); (void)tex_mtl(&t); mtl_wait(mtl_sub_commit(), 5000000000ull); while (atomic_load(&g_up_pending)) usleep(200);
    }
    EXPECT("pooled blocks reused by later batches", 1, g_up_pool_hits > 0);
    EXPECT("at most UP_POOL blocks made", 1, g_up_pool_n <= UP_POOL);
    uint8_t px[64 * 64 * 4]; NVNcopyRegion r = {0, 0, 0, 64, 64, 1};
    id<MTLTexture> mt = tex_mtl(&t); id<MTLBuffer> rb = [g_dev newBufferWithLength:sizeof px options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromTexture:mt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(64,64,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:sizeof px];
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted]; memcpy(px, rb.contents, sizeof px); (void)r;
    uint32_t v; memcpy(&v, px + (17 * 64 + 33) * 4, 4);
    EXPECT("the last texture, uploaded through a reused block, is right", last, v);
    {   // the census by last use: 500 submissions on, texture 9700 used again in a submission
        g_sub_serial += 500;
        tex_t t0 = {.serial = 9700}; t0.d.width = t0.d.height = 64; t0.d.depth = t0.d.samples = t0.d.levels = 1; t0.d.target = NVN_TEXTURE_TARGET_2D; t0.d.format = NVN_FORMAT_RGBA8;
        nvn_texlayout L; nvn_tex_layout(&t0.d, &L); t0.size = (uint32_t)L.size; t0.mem = mem; t0.pool = &pl;
        mtl_sub_begin(); (void)tex_mtl(&t0); mtl_wait(mtl_sub_commit(), 5000000000ull);
        pkg_census(); uint64_t ag[5]; mtl_pkg_age(ag); uint64_t one = (uint64_t)tex_mtl(&t0).allocatedSize;
        printf("census: %llu textures, %llu / %llu / %llu / %llu bytes\n", ag[4], ag[0], ag[1], ag[2], ag[3]);
        EXPECT("census: twelve uploaded textures", 12, ag[4]);
        EXPECT("census: the one used again, in the last 30 submissions", one, ag[0]);
        EXPECT("census: the eleven others, 301-1800 submissions ago", 11 * one, ag[2]);
    }
    printf("== %d checks, %d failed ==\n", count, fail); return fail != 0;
} }
