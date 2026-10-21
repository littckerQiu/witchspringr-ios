// GPU results written back on nvnMemoryPoolInvalidateMappedRange (nvn_mtl.m wb_note / mtl_pool_invalidate; MacNativeGames): a CPU-filled texture in a
// CPU-visible pool that the GPU then renders into keeps the result only in its MTLTexture; an invalidate over its storage writes it back in the NVN
// layout, unless the CPU wrote the storage after the rendering (then the CPU's bytes stay).
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, want, got) do { long long w=(want), g=(got); count++; printf("%-74s expected %-10llx → got %-10llx %s\n", name, (unsigned long long)w, (unsigned long long)g, w==g?"✓":"✗"); fail += w != g; } while (0)
typedef struct { uint8_t *p; size_t n; } chain;
static void emit(chain *c, unsigned op, const void *a, size_t n) { size_t z=(8+n+7)&~7ull; op_hdr h={op,(uint32_t)z}; memcpy(c->p+c->n,&h,8); if(n) memcpy(c->p+c->n+8,a,n); c->n+=z; }
static void render_clear(const tex_t *t, float r, float g, float b) {   // one submission: a render pass on t cleared to (r, g, b, 1)
    static uint8_t *cm; if (!cm) { if (posix_memalign((void **)&cm, getpagesize(), 65536)) abort(); mtl_pool_add(cm, 65536); }
    chain c = {cm, 0}; memset(cm, 0, 65536);
    p_set_rt rt = {.n = 1}; rt.color[0] = t; emit(&c, OP_SET_RT, &rt, sizeof rt);
    p_clear_color x = {.index = 0, .mask = 15, .rgba = {r, g, b, 1}}; emit(&c, OP_CLEAR_COLOR, &x, sizeof x);
    emit(&c, OP_END, NULL, 0);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); uint64_t hh = (uint64_t)c.p; mtl_sub_index(&hh, 1); mtl_exec(c.p); mtl_wait(mtl_sub_commit(), 5000000000ull);
}
static uint32_t texel(const tex_t *t, unsigned x, unsigned y) { uint32_t lin[64]; nvn_deswizzle(&t->d, 0, 0, t->mem, lin, 32); return lin[y * 8 + x]; }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); mtl_init();
    uint8_t *mem; if (posix_memalign((void **)&mem, getpagesize(), 1 << 20)) abort(); memset(mem, 0, 1 << 20); mtl_pool_add(mem, 1 << 20);
    nvn_dirty_add_range(mem, 1 << 20);   // as nvnMemoryPoolInitialize registers a CPU-visible pool (an untracked range counts as written)
    static pool_t pl; pl.mem = mem; pl.size = 1 << 20; pl.flags = NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED;
    tex_t t = {.serial = 9990}; t.d.width = t.d.height = 8; t.d.depth = t.d.samples = t.d.levels = 1; t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = NVN_FORMAT_RGBA8;
    nvn_texlayout L; nvn_tex_layout(&t.d, &L); t.size = (uint32_t)L.size; t.mem = mem; t.pool = &pl;
    uint32_t lin[64]; for (int i = 0; i < 64; i++) lin[i] = 0x11223344; nvn_swizzle(&t.d, 0, 0, lin, 32, t.mem);   // the CPU fills it
    render_clear(&t, 0, 1, 0);
    EXPECT("after the GPU rendered green: memory still holds what the CPU wrote", 0x11223344, texel(&t, 3, 5));
    mtl_pool_invalidate(&pl, 0, t.size);
    EXPECT("after an invalidate over it: green written back (texel 3,5)", 0xff00ff00, texel(&t, 3, 5));
    EXPECT("... and texel 7,7", 0xff00ff00, texel(&t, 7, 7));
    render_clear(&t, 0, 0, 1);
    mtl_pool_invalidate(&pl, 0x40000, 0x1000);   // a range elsewhere in the pool
    EXPECT("an invalidate of another range writes nothing back", 0xff00ff00, texel(&t, 3, 5));
    for (int i = 0; i < 64; i++) lin[i] = 0x55667788; dm_guest_write_prepare(t.mem, t.size); nvn_swizzle(&t.d, 0, 0, lin, 32, t.mem);   // the CPU writes after the rendering
    mtl_pool_invalidate(&pl, 0, t.size);
    EXPECT("the CPU wrote after the GPU rendered blue: its bytes stay", 0x55667788, texel(&t, 3, 5));
    printf("== %d checks, %d failed ==\n", count, fail); return fail != 0;
} }
