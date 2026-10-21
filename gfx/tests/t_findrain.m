// Released textures' views (nvn_mtl.m fin_drain → treg_drop_views): every texture ID that names a released texture drops its view and is marked
// finalized, and only those. All the serials released at one submission are looked up in one walk of the registrations; one walk per serial cost
// Tears of the Kingdom 0.28 ms a submission (30 releases × 33,000 registrations). A serial between two released ones must stay (a set, not a range).
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, want, got) do { long long w=(want), g=(got); count++; printf("%-80s expected %-6lld → got %-6lld %s\n", name, w, g, w==g?"✓":"✗"); fail += w != g; } while (0)
static uint8_t *g_mem;
static tex_t tex_at(size_t off) {   // as nvnTextureInitialize makes it
    static uint64_t s = 7700; tex_t t = {.serial = s++}; t.d.width = t.d.height = 8; t.d.depth = t.d.samples = t.d.levels = 1; t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = NVN_FORMAT_RGBA8;
    nvn_texlayout L; nvn_tex_layout(&t.d, &L); t.size = (uint32_t)L.size; t.mem = g_mem + off; mtl_tex_live(&t); return t;
}
static id<MTLTexture> by_id(int tid) { pthread_mutex_lock(&g_rmu); id<MTLTexture> v = tex_by_id(tid); pthread_mutex_unlock(&g_rmu); return v; }
static void drain_past_grace(void) { fin_drain(); g_sub_serial += FIN_GRACE; fin_drain(); }   // the first drain sets the due submission, the second passes it
static int dropped(int tid) { return g_treg[tid].fin && !g_treg[tid].view; }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); mtl_init();
    if (posix_memalign((void **)&g_mem, getpagesize(), 1 << 22)) abort(); memset(g_mem, 0, 1 << 22); mtl_pool_add(g_mem, 1 << 22);
    // A < C < B; A on IDs 3, 4, 5, C on 6, B on 7 and 8; every ID has a view
    tex_t a = tex_at(0), c = tex_at(0x10000), b = tex_at(0x20000);
    int ida[] = {3, 4, 5}, idb[] = {7, 8};
    for (int k = 0; k < 3; k++) mtl_reg_tex(ida[k], &a, NULL);
    mtl_reg_tex(6, &c, NULL);
    for (int k = 0; k < 2; k++) mtl_reg_tex(idb[k], &b, NULL);
    int views = 0; for (int i = 3; i <= 8; i++) { by_id(i); views += g_treg[i].view != NULL; }
    EXPECT("six IDs with a view each", 6, views);
    mtl_tex_release(&a); mtl_tex_release(&b); drain_past_grace();
    int n = 0; for (int k = 0; k < 3; k++) n += dropped(ida[k]); for (int k = 0; k < 2; k++) n += dropped(idb[k]);
    EXPECT("A and B released at one submission: their five IDs dropped their views", 5, n);
    EXPECT("C, between them, keeps its view", 1, g_treg[6].view != NULL && !g_treg[6].fin);
    // 64 released at once (fin_drain's batch): all found, whatever their places in the set
    enum { M = 64 }; static tex_t many[M];
    for (int k = 0; k < M; k++) { many[k] = tex_at(0x40000 + (size_t)k * 0x1000); mtl_reg_tex(100 + k, &many[k], NULL); by_id(100 + k); }
    for (int k = 0; k < M; k++) mtl_tex_release(&many[k]);
    drain_past_grace();
    n = 0; for (int k = 0; k < M; k++) n += dropped(100 + k);
    EXPECT("64 released at one submission: all 64 IDs dropped their views", M, n);
    EXPECT("C still keeps its view", 1, g_treg[6].view != NULL && !g_treg[6].fin);
    // Cost: 33,000 registrations; serials looked up that none of them holds, inside their range. One walk for 30 serials, not 30 walks
    enum { NREG = 33000 };
    for (int i = 0; i < NREG; i++) { tex_t t = {.serial = 1000000 + 2 * (uint64_t)i}; t.d.width = t.d.height = 1; mtl_reg_tex(1000 + i, &t, NULL); }
    uint64_t miss[30]; for (int k = 0; k < 30; k++) miss[k] = 1000001 + 2 * (uint64_t)(k * 1000);
    uint64_t best1 = UINT64_MAX, best30 = UINT64_MAX;
    for (int r = 0; r < 20; r++) {
        uint64_t t0 = bp_now(); treg_drop_views(miss, 1); uint64_t t1 = bp_now(); treg_drop_views(miss, 30); uint64_t t2 = bp_now();
        best1 = MIN(best1, t1 - t0); best30 = MIN(best30, t2 - t1);
    }
    printf("view drop over %d registrations: 1 serial %llu ns, 30 serials %llu ns\n", NREG, (unsigned long long)best1, (unsigned long long)best30);
    EXPECT("30 serials cost under 8 times what 1 does (one walk; one walk each was 30 times)", 1, best30 < 8 * best1);
    n = 0; for (int i = 0; i < NREG; i++) n += g_treg[1000 + i].fin;
    EXPECT("... and none of the 33,000 was touched", 0, n);
    printf("== %d checks, %d failed ==\n", count, fail); return fail != 0;
} }
