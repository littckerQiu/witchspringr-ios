// A texture ID whose texture was finalized follows its storage to the texture initialized there since (nvn_mtl.m tex_by_id, mtl_tex_live;
// MacNativeGames' live_put): Tears of the Kingdom re-initializes transient render targets at the same storage every frame without registering
// their IDs again, and the IDs read the old texture, then a blank one. Not followed: a replacement of another shape, a texture still alive.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, want, got) do { long long w=(want), g=(got); count++; printf("%-78s expected %-4lld → got %-4lld %s\n", name, w, g, w==g?"✓":"✗"); fail += w != g; } while (0)
static uint8_t *g_mem;
static tex_t tex_at(size_t off, int format) {   // as nvnTextureInitialize makes it
    static uint64_t s = 9900; tex_t t = {.serial = s++}; t.d.width = t.d.height = 8; t.d.depth = t.d.samples = t.d.levels = 1; t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = format;
    nvn_texlayout L; nvn_tex_layout(&t.d, &L); t.size = (uint32_t)L.size; t.mem = g_mem + off; mtl_tex_live(&t); return t;
}
static id<MTLTexture> by_id(int tid) { pthread_mutex_lock(&g_rmu); id<MTLTexture> v = tex_by_id(tid); pthread_mutex_unlock(&g_rmu); return v; }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); mtl_init();
    if (posix_memalign((void **)&g_mem, getpagesize(), 1 << 20)) abort(); memset(g_mem, 0, 1 << 20); mtl_pool_add(g_mem, 1 << 20);
    tex_t a = tex_at(0, NVN_FORMAT_RGBA8); mtl_reg_tex(7, &a, NULL);
    id<MTLTexture> va = by_id(7);
    EXPECT("the ID reads its texture", 1, va != nil && va == tex_mtl(&a));
    tex_t b0 = tex_at(0x10000, NVN_FORMAT_RGBA8);   // another texture elsewhere, while a is alive
    EXPECT("a texture initialized elsewhere changes nothing", 1, by_id(7) == va);
    mtl_tex_release(&a); tex_t b = tex_at(0, NVN_FORMAT_RGBA8);   // a finalized, b initialized at its storage
    id<MTLTexture> vb = by_id(7);
    EXPECT("finalized and replaced at its storage by the same shape: the ID reads the new one", 1, vb != nil && vb == tex_mtl(&b));
    EXPECT("... and its serial", (long long)b.serial, (long long)atomic_load(&g_tser[7]));
    mtl_tex_release(&b); tex_t c = tex_at(0, NVN_FORMAT_RGBA16F);   // replaced by another format
    EXPECT("replaced by another format: not followed", 1, by_id(7) == vb);
    tex_t d = tex_at(0x20000, NVN_FORMAT_RGBA8); mtl_reg_tex(9, &d, NULL); id<MTLTexture> vd = by_id(9);
    tex_t e = tex_at(0x20000, NVN_FORMAT_RGBA8);   // initialized over d while d is not finalized (aliasing): d stays
    EXPECT("a texture initialized over one not finalized: not followed", 1, by_id(9) == vd);
    // An identical registration changes nothing (mtl_reg_tex): same generation, same view; a different one does
    tex_t f = tex_at(0x30000, NVN_FORMAT_RGBA8); mtl_reg_tex(11, &f, NULL); id<MTLTexture> vf = by_id(11); uint64_t g0 = g_reg_gen;
    mtl_reg_tex(11, &f, NULL);
    EXPECT("the same registration again: generation unchanged", (long long)g0, (long long)g_reg_gen);
    EXPECT("... and the slot keeps its texture", 1, by_id(11) == vf);
    tex_t h = tex_at(0x40000, NVN_FORMAT_RGBA8); mtl_reg_tex(11, &h, NULL);
    EXPECT("another texture: generation bumped", 1, g_reg_gen != g0);
    EXPECT("... and the slot reads it", 1, by_id(11) == tex_mtl(&h));
    (void)b0; (void)c; (void)e;
    printf("== %d checks, %d failed ==\n", count, fail); return fail != 0;
} }
