// What a texture's checks cost (nvn_mtl.m; MacNativeGames, MIT): a CPU-filled texture is checked once per submission (tex_mtl, csub), a small one by its
// content instead of write-protected pages (pkg_hashed), a texture ID's cached view survives generation steps for other serials (ser_unaffected) and,
// for a texture that does not follow guest memory, guest writes (treg_kind / treg_stamp); nvn_dirty_state answers tracked + written in one lookup.
// Negative controls: DM_NVN_CHECK_ONCE=0 and DM_NVN_PKG_HASH=0 fail the checks marked so.
// A re-upload writes into the texture before the last one once no submission reads it (the spare), with the new content; a spare still in use is
// not touched; a spare unused for PKG_SPARE_KEEP submissions is released.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
void crash_install(void);
static int fail, count;
#define EXPECT(name, want, got) do { long long w=(want), g=(got); count++; printf("%-86s expected %-6lld → got %-6lld %s\n", name, w, g, w==g?"✓":"✗"); fail += w != g; } while (0)
static uint8_t *g_mem; static pool_t g_pl;
static tex_t tex_new(uint64_t serial, unsigned w, unsigned h, size_t off, int cpu_pool) {
    tex_t t = {.serial = serial}; t.d.width = w; t.d.height = h; t.d.depth = t.d.samples = t.d.levels = 1; t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = NVN_FORMAT_RGBA8;
    nvn_texlayout L; nvn_tex_layout(&t.d, &L); t.size = (uint32_t)L.size; t.mem = g_mem + off; t.pool = cpu_pool ? &g_pl : NULL; return t;
}
static void fill(const tex_t *t, uint32_t v) { for (uint32_t i = 0; i < t->size / 4; i++) ((uint32_t *)(void *)t->mem)[i] = v + i; }
static id<MTLTexture> by_id(int tid) { pthread_mutex_lock(&g_rmu); id<MTLTexture> v = tex_by_id(tid); pthread_mutex_unlock(&g_rmu); return v; }
static void sub_begin(void) { state_reset(); mtl_sub_begin(); }
static void sub_end(void) { mtl_wait(mtl_sub_commit(), 5000000000ull); }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); mtl_init();
    crash_install();   // production SIGSEGV / SIGBUS handling: a write to a protected page goes through the page-fault hook (the DM_NVN_PKG_HASH=0 control writes one)
    if (posix_memalign((void **)&g_mem, getpagesize(), 1 << 20)) abort(); memset(g_mem, 0, 1 << 20); mtl_pool_add(g_mem, 1 << 20);
    nvn_dirty_add_range(g_mem, 1 << 20);
    g_pl.mem = g_mem; g_pl.size = 1 << 20; g_pl.flags = NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED;
    // 1. nvn_dirty_state
    static uint8_t outside[64];
    EXPECT("nvn_dirty_state: memory outside every range is not tracked (2)", 2, nvn_dirty_state(outside, sizeof outside, 0));
    uint8_t *pg = g_mem + 0xE0000; nvn_dirty_protect(pg, 16384); uint64_t st = nvn_dirty_now();
    EXPECT("nvn_dirty_state: tracked, not written since (0)", 0, nvn_dirty_state(pg, 64, st));
    dm_guest_write_prepare(pg, 4); pg[0] = 1;
    EXPECT("nvn_dirty_state: written since (1)", 1, nvn_dirty_state(pg, 64, st));
    EXPECT("... as nvn_dirty_since says", 1, nvn_dirty_since(pg, 64, st));
    // 2. ser_unaffected
    uint64_t g0 = g_ser_gen; ser_bump(5); ser_bump(6); uint64_t g1 = g_ser_gen;
    EXPECT("steps for serials 5 and 6 leave serial 7", 1, ser_unaffected(g0, g1, 7));
    EXPECT("... not serial 5", 0, ser_unaffected(g0, g1, 5));
    ser_bump(0); EXPECT("a step for every serial (0) leaves none", 0, ser_unaffected(g0, g_ser_gen, 7));
    uint64_t g2 = g_ser_gen; for (int i = 0; i < SER_CHG_N + 10; i++) ser_bump(8);
    EXPECT("more steps than the ring holds: not known, so affected", 0, ser_unaffected(g2, g_ser_gen, 7));
    // 3. A GPU texture's view (kind 0): kept through steps for other serials and through guest writes; checked again after a step for its own serial.
    //    Its MTLTexture is replaced behind the table's back, so the old view coming back shows the check was skipped
    tex_t x = tex_new(7100, 8, 8, 0x80000, 0); mtl_reg_tex(20, &x, NULL);
    id<MTLTexture> v1 = by_id(20);
    EXPECT("GPU texture: looked up again, the same view (made before its texture's own table step: checked once more)", 1, v1 != nil && by_id(20) == v1);
    MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
    id<MTLTexture> other = [g_dev newTextureWithDescriptor:od];
    pthread_mutex_lock(&g_smu); hm_put_id(&g_by_serial, &x.serial, other); pthread_mutex_unlock(&g_smu);   // no step for 7100
    ser_bump(7101);
    EXPECT("GPU texture: a step for another serial keeps its view", 1, v1 != nil && by_id(20) == v1);
    nvn_dirty_protect(pg, 16384); uint64_t d0 = nvn_dirty_now(); dm_guest_write_prepare(pg, 4); pg[1] = 2;
    EXPECT("GPU texture: a guest write elsewhere keeps its view", 1, nvn_dirty_now() != d0 && by_id(20) == v1);
    ser_bump(x.serial);
    EXPECT("GPU texture: a step for its own serial checks it again (the replaced texture)", 1, by_id(20) == other);
    // 4. A CPU-filled texture (64x32 RGBA8, above PKG_HASH_MAX): checked once per submission, through its ID's view too
    tex_t p = tex_new(7200, 64, 32, 0x10000, 1); fill(&p, 0x01000000); mtl_reg_tex(30, &p, NULL);
    uint64_t up0, re0, up, re; mtl_pkg_stats(&up0, &re0);
    sub_begin();
    id<MTLTexture> t1 = tex_mtl(&p), w1 = by_id(30);
    mtl_pkg_stats(&up, &re); EXPECT("CPU-filled texture: uploaded at first use", 1, (long long)(up - up0));
    dm_guest_write_prepare(p.mem, p.size); fill(&p, 0x02000000);
    EXPECT("written during the submission: the same submission keeps its texture [DM_NVN_CHECK_ONCE=0 fails]", 1, tex_mtl(&p) == t1);
    EXPECT("... and its ID keeps its view [DM_NVN_CHECK_ONCE=0 fails]", 1, by_id(30) == w1);
    sub_end();
    sub_begin();
    id<MTLTexture> t2 = tex_mtl(&p);
    mtl_pkg_stats(&up, &re);
    EXPECT("the next submission re-uploads it", 1, t2 != nil && t2 != t1 && re - re0 == 1);
    EXPECT("... and its ID reads the new one", 1, by_id(30) == t2);
    sub_end();
    sub_begin(); EXPECT("not written: the next submission keeps it", 1, tex_mtl(&p) == t2); sub_end();
    // 4b. The spare: t1 became the spare when t2 was uploaded; written again, the next re-upload writes into t1 (its submission has completed)
    {   uint64_t r0 = g_pkg_spare_reuse;
        sub_begin(); dm_guest_write_prepare(p.mem, p.size); fill(&p, 0x03000000); sub_end();
        sub_begin(); id<MTLTexture> t3 = tex_mtl(&p); sub_end(); up_wait_zero(&g_up_pending);
        EXPECT("4b. third upload: written into the spare (the first texture)", 1, t3 == t1 && g_pkg_spare_reuse - r0 == 1);
        id<MTLCommandQueue> q = [g_dev newCommandQueue]; id<MTLBuffer> rb = [g_dev newBufferWithLength:64 * 32 * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromTexture:t3 sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(64, 32, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256 * 32];
        [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
        static uint32_t lin[64 * 32]; int nz = 0; memcpy(lin, rb.contents, sizeof lin); for (int i = 0; i < 64 * 32; i++) nz += (lin[i] >> 24) == 3;
        EXPECT("4b. ... holding the new content (every texel from the third fill)", 64 * 32, nz);
        NvPkg *pk = (NvPkg *)serial_get(p.serial); pk->spare_fence = g_fence + 1000;   // as if a submission still read the spare (t2)
        sub_begin(); dm_guest_write_prepare(p.mem, p.size); fill(&p, 0x04000000); sub_end();
        uint64_t r1 = g_pkg_spare_reuse; sub_begin(); id<MTLTexture> t4 = tex_mtl(&p); sub_end();
        EXPECT("4b. a spare still in use is not written: a new texture", 1, t4 != t2 && t4 != t3 && g_pkg_spare_reuse == r1);
        uint64_t d0 = g_pkg_spare_drop;
        for (int i = 0; i < PKG_SPARE_KEEP + 2; i++) { sub_begin(); sub_end(); }
        sub_begin(); EXPECT("4b. not re-uploaded for PKG_SPARE_KEEP submissions: the spare is released", 1, tex_mtl(&p) == t4 && g_pkg_spare_drop - d0 == 1 && pk->spare == nil); sub_end(); }
    // 5. A small CPU-filled texture (8x8 RGBA8, 256 bytes): its pages are not write-protected; a change is found by its content at the next submission
    tex_t s = tex_new(7300, 8, 8, 0xC0000, 1); fill(&s, 0x03000000);
    sub_begin(); id<MTLTexture> s1 = tex_mtl(&s); sub_end();
    uint64_t f0, p0, f1, p1; nvn_dirty_stats(&f0, &p0); uint64_t n0 = nvn_dirty_now();
    fill(&s, 0x04000000);   // a plain write, as a game thread's
    nvn_dirty_stats(&f1, &p1);
    EXPECT("small texture: a CPU write takes no page fault [DM_NVN_PKG_HASH=0 fails]", 0, (long long)(f1 - f0));
    EXPECT("... and does not step the guest-write generation [DM_NVN_PKG_HASH=0 fails]", 1, nvn_dirty_now() == n0);
    sub_begin(); id<MTLTexture> s2 = tex_mtl(&s); sub_end();
    EXPECT("small texture: the next submission finds the new content and re-uploads", 1, s2 != nil && s2 != s1);
    sub_begin(); EXPECT("small texture: unchanged content, kept", 1, tex_mtl(&s) == s2); sub_end();
    fill(&s, 0x04000000);   // the same bytes written again
    sub_begin(); EXPECT("small texture: the same bytes written again, kept (no false change)", 1, tex_mtl(&s) == s2); sub_end();
    printf("== %d checks, %d failed ==\n", count, fail); return fail != 0;
} }
