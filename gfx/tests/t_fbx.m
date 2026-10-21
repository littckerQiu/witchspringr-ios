// Draws that sample what their own pass draws (nvn_mtl.m fbx_prepare / fbx_sub, plan item 42), on the GPU through the production replay: an 8x8
// RGBA8 target, programs that write a constant (B, C) and one that reads the target at its pixel and adds 0.25.
// Default (a copy only after a texture-invalidating barrier that follows draws of the pass, as NVN defines it):
//   a   clear 0.1, B, barrier, the reading draw: B + 0.25, one copy
//   a2  C in an earlier pass; then B and the reading draw without a barrier: C + 0.25 (what the pass started with, as the console shows), no copy
//   c1  B, barrier, two reading draws: the second sees what its reopened pass started with, B + 0.25; one copy
//   c2  the same with a barrier between the reading draws: B + 0.5, two copies
//   e   drawing level 1 while sampling a view of level 0 only: C + 0.25 in level 1, no copy
// DM_NVN_FBX=all (every such draw; tomodachi-native's choice): a and c without barriers (B + 0.25, B + 0.5), b (the first draw of a pass reads
// what earlier passes left), f (a clear still pending when the reading draw opens the pass is in the copy), e.
// After tomodachi-native's attachment copies (4dbd30f / da08d11, MIT), written for this replay. Negative control: DM_NVN_FBX=0 fails a, c2
// (and in the all set a, c, f).
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, want, got) do { uint64_t w = (want), g = (got); count++; printf("%-78s expected %-4llu → got %-4llu %s\n", name, (unsigned long long)w, (unsigned long long)g, w == g ? "✓" : "✗"); fail += w != g; } while (0)
typedef struct { uint8_t *p; size_t n; } chain;
static chain chain_new(void) { chain c = {0}; if (posix_memalign((void **)&c.p, getpagesize(), 65536)) abort(); memset(c.p, 0, 65536); mtl_pool_add(c.p, 65536); return c; }
static void emit(chain *c, unsigned op, const void *a, size_t n) { size_t z = (8 + n + 7) & ~7ull; op_hdr h = {op, (uint32_t)z}; memcpy(c->p + c->n, &h, 8); if (n) memcpy(c->p + c->n + 8, a, n); c->n += z; }
static tex_t tex(void) { static uint64_t s = 9600; tex_t t = {.serial = s++}; t.d.width = t.d.height = 8; t.d.depth = t.d.samples = 1; t.d.levels = 2; t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = NVN_FORMAT_RGBA8; return t; }
static int view(const tex_t *t, int lv) { static int id = 1600; view_t v = {.set_levels = 1, .base_level = lv, .nlevels = 1}; mtl_reg_tex(id, t, &v); return id++; }
static void set_rt(chain *c, const tex_t *a, int lv) {
    p_set_rt r = {.n = 1}; r.color[0] = a; r.has_cview[0] = 1; r.cview[0].set_levels = 1; r.cview[0].base_level = lv; r.cview[0].nlevels = 1; emit(c, OP_SET_RT, &r, sizeof r);
    int w = 8 >> lv; p_viewports v = {.n = 1}; v.v[0][2] = v.v[0][3] = w; emit(c, OP_VIEWPORTS, &v, sizeof v); p_scissor sc = {0, 0, w, w}; emit(c, OP_SCISSOR, &sc, sizeof sc);
}
static void clear_color(chain *c, float x) { p_clear_color k = {.index = 0, .mask = 15, .rgba = {x, x, x, 1}}; emit(c, OP_CLEAR_COLOR, &k, sizeof k); }
static void bind_prog(chain *c, prog_t *p) { p_bind_program b = {p, 3}; emit(c, OP_BIND_PROGRAM, &b, sizeof b); }
static void bind_tex(chain *c, int id) { p_bind_handles b = {.stage = 1, .first = 0, .n = 1}; b.h[0] = id; emit(c, OP_BIND_TEX, &b, sizeof b); }
static void draw_cmd(chain *c) { p_draw d = {NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3}; emit(c, OP_DRAW, &d, sizeof d); }
static void ds_off(chain *c) { ds_st d = {0, 0, NVN_DEPTH_FUNC_ALWAYS, 0, NVN_STENCIL_FUNC_ALWAYS, NVN_STENCIL_FUNC_ALWAYS, NVN_STENCIL_OP_KEEP, NVN_STENCIL_OP_KEEP, NVN_STENCIL_OP_KEEP, NVN_STENCIL_OP_KEEP, NVN_STENCIL_OP_KEEP, NVN_STENCIL_OP_KEEP};
    p_bind_state x = {.kind = 5}; memcpy(x.bytes, &d, sizeof d); emit(c, OP_BIND_STATE, &x, sizeof x); }
static prog_t g_pB, g_pC, g_pAdd; static NvProg *g_tfbx_keep[3];
static void setup(void) {
    NSError *e = nil;
    id<MTLLibrary> l = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint n [[vertex_id]]) { float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; return float4(p[n], 0, 1); }\n"
        "fragment float4 cB() { return float4(0.5, 0.25, 0.125, 1); }\n"
        "fragment float4 cC() { return float4(0.2, 0.4, 0.6, 1); }\n"
        "struct A { texture2d<float> t [[id(0)]]; };\n"
        "fragment float4 add(float4 pos [[position]], constant A &a [[buffer(0)]]) { return float4(a.t.read(uint2(pos.xy)).rgb + 0.25, 1); }\n" options:nil error:&e];
    if (!l) { printf("%s\n", e.localizedDescription.UTF8String); abort(); }
    prog_t *pg[3] = {&g_pB, &g_pC, &g_pAdd}; NSString *fn[3] = {@"cB", @"cC", @"add"};
    for (int i = 0; i < 3; i++) {
        NvProg *p = [NvProg new]; p->sh[0] = [NvShader new]; p->sh[0]->fn = [l newFunctionWithName:@"v"];
        p->sh[1] = [NvShader new]; p->sh[1]->stage = 1; p->sh[1]->fn = [l newFunctionWithName:fn[i]];
        if (i == 2) { p->sh[1]->rf.nb = 1; p->sh[1]->rf.b[0] = (nvn_rbind){.kind = NVN_RB_TEX, .reg = 0, .dtt = 2}; p->sh[1]->ae = [p->sh[1]->fn newArgumentEncoderWithBufferIndex:0]; }
        pg[i]->serial = 9700 + i; serial_put(pg[i]->serial, p); g_tfbx_keep[i] = p;
    }
}
// Runs the chain, returns pixel (3,3) of the level as 0xRRGGBB
static uint32_t run(chain *c, const tex_t *t, int lv) {
    emit(c, OP_END, NULL, 0); state_reset(); memset(&R, 0, sizeof R);
    mtl_sub_begin(); uint64_t hh = (uint64_t)c->p; mtl_sub_index(&hh, 1); mtl_exec(c->p);
    int w = 8 >> lv; id<MTLBuffer> b = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    [blit() copyFromTexture:tex_mtl(t) sourceSlice:0 sourceLevel:(NSUInteger)lv sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, w, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:(NSUInteger)w * 4 destinationBytesPerImage:(NSUInteger)w * w * 4];
    if (!mtl_wait(mtl_sub_commit(), 5000000000ull) || mtl_last_commit_error()) { printf("GPU did not complete\n"); abort(); }
    const uint8_t *px = (const uint8_t *)b.contents + (3 * w + 3) * 4; return (uint32_t)px[0] << 16 | (uint32_t)px[1] << 8 | px[2];
}
static int near(uint32_t got, float r, float g, float b) {   // within 2 of each 8-bit channel
    int want[3] = {(int)lroundf(fminf(r, 1) * 255), (int)lroundf(fminf(g, 1) * 255), (int)lroundf(fminf(b, 1) * 255)};
    for (int k = 0; k < 3; k++) if (abs((int)(got >> (16 - 8 * k) & 255) - want[k]) > 2) return 0;
    return 1;
}
static uint64_t copies(void) { uint64_t s[3]; mtl_fbx_stats(s); return s[1]; }

static void barrier(chain *c) { int32_t b = NVN_BARRIER_ORDER_FRAGMENTS_BIT | NVN_BARRIER_INVALIDATE_TEXTURE_BIT; emit(c, OP_BARRIER, &b, 8); }
static void begin_b(chain *c, tex_t *T) { set_rt(c, T, 0); clear_color(c, 0.1f); ds_off(c); bind_prog(c, &g_pB); draw_cmd(c); }
static void reading(chain *c, int v0) { bind_prog(c, &g_pAdd); bind_tex(c, v0); draw_cmd(c); }

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); mtl_init(); setup();
    const char *m = getenv("DM_NVN_FBX"); int all = m && !strcmp(m, "all");
    printf("attachment copies: %s\n", !m ? "after a texture barrier (default)" : m);
    if (!all) {
        { tex_t T = tex(); int v0 = view(&T, 0); chain c = chain_new(); uint64_t c0 = copies(); begin_b(&c, &T); barrier(&c); reading(&c, v0);
          uint32_t px = run(&c, &T, 0); printf("     a: %06x\n", px);
          EXPECT("a   after a barrier the reading draw sees the earlier draw (B + 0.25)", 1, near(px, 0.75f, 0.5f, 0.375f));
          EXPECT("a   ... one copy", 1, copies() - c0); }
        { tex_t T = tex(), U = tex(); int v0 = view(&T, 0); chain c = chain_new(); uint64_t c0 = copies();   // (a pass on U between: the two passes on T are not merged)
          set_rt(&c, &T, 0); clear_color(&c, 0); ds_off(&c); bind_prog(&c, &g_pC); draw_cmd(&c);
          set_rt(&c, &U, 0); clear_color(&c, 0); draw_cmd(&c);
          set_rt(&c, &T, 0); bind_prog(&c, &g_pB); draw_cmd(&c); reading(&c, v0);
          uint32_t px = run(&c, &T, 0); printf("     a2: %06x\n", px);
          EXPECT("a2  without a barrier it reads what the pass started with (C + 0.25)", 1, near(px, 0.45f, 0.65f, 0.85f));
          EXPECT("a2  ... no copy", 0, copies() - c0); }
        { tex_t T = tex(); int v0 = view(&T, 0); chain c = chain_new(); uint64_t c0 = copies(); begin_b(&c, &T); barrier(&c); reading(&c, v0); reading(&c, v0);
          uint32_t px = run(&c, &T, 0); printf("     c1: %06x\n", px);
          EXPECT("c1  a second reading draw with no barrier before it: B + 0.25", 1, near(px, 0.75f, 0.5f, 0.375f));
          EXPECT("c1  ... one copy", 1, copies() - c0); }
        { tex_t T = tex(); int v0 = view(&T, 0); chain c = chain_new(); uint64_t c0 = copies(); begin_b(&c, &T); barrier(&c); reading(&c, v0); barrier(&c); reading(&c, v0);
          uint32_t px = run(&c, &T, 0); printf("     c2: %06x\n", px);
          EXPECT("c2  a barrier between two reading draws: B + 0.5", 1, near(px, 1.0f, 0.75f, 0.625f));
          EXPECT("c2  ... two copies", 2, copies() - c0); }
    } else {
        { tex_t T = tex(); int v0 = view(&T, 0); chain c = chain_new(); uint64_t c0 = copies(); begin_b(&c, &T); reading(&c, v0);
          uint32_t px = run(&c, &T, 0); printf("     a: %06x\n", px);
          EXPECT("a   (all) the reading draw after a draw in its pass sees that draw (B + 0.25)", 1, near(px, 0.75f, 0.5f, 0.375f));
          EXPECT("a   ... one copy", 1, copies() - c0); }
        { tex_t T = tex(); int v0 = view(&T, 0); chain c = chain_new(); uint64_t c0 = copies(); begin_b(&c, &T); reading(&c, v0); reading(&c, v0);
          uint32_t px = run(&c, &T, 0); printf("     c: %06x\n", px);
          EXPECT("c   (all) two reading draws in a row: the second sees the first (B + 0.5)", 1, near(px, 1.0f, 0.75f, 0.625f));
          EXPECT("c   ... two copies", 2, copies() - c0); }
        { tex_t T = tex(); int v0 = view(&T, 0); chain c = chain_new(); uint64_t c0 = copies();
          set_rt(&c, &T, 0); clear_color(&c, 0); ds_off(&c); bind_prog(&c, &g_pC); draw_cmd(&c); set_rt(&c, &T, 0); reading(&c, v0);
          uint32_t px = run(&c, &T, 0); printf("     b: %06x\n", px);
          EXPECT("b   (all) the first draw of a pass reads what earlier passes left (C + 0.25)", 1, near(px, 0.45f, 0.65f, 0.85f));
          EXPECT("b   ... one copy", 1, copies() - c0); }
        { tex_t T = tex(); int v0 = view(&T, 0); chain c = chain_new(); uint64_t c0 = copies(); set_rt(&c, &T, 0); clear_color(&c, 0.3f); ds_off(&c); reading(&c, v0);
          uint32_t px = run(&c, &T, 0); printf("     f: %06x\n", px);
          EXPECT("f   (all) a pending clear: the reading draw sees it (0.3 + 0.25)", 1, near(px, 0.55f, 0.55f, 0.55f));
          EXPECT("f   ... one copy", 1, copies() - c0); }
    }
    { tex_t T = tex(); int v0 = view(&T, 0); chain c = chain_new(); uint64_t c0 = copies();
      set_rt(&c, &T, 0); clear_color(&c, 0); ds_off(&c); bind_prog(&c, &g_pC); draw_cmd(&c); barrier(&c);
      set_rt(&c, &T, 1); reading(&c, v0);
      uint32_t px = run(&c, &T, 1); printf("     e: %06x\n", px);
      EXPECT("e   drawing level 1, sampling level 0: C + 0.25 in level 1", 1, near(px, 0.45f, 0.65f, 0.85f));
      EXPECT("e   ... no copy (the level it reads is not the one it draws)", 0, copies() - c0); }
    printf("== %d checks, %d failed ==\n", count, fail); return fail != 0;
} }
