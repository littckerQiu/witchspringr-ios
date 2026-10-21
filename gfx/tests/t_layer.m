// Layered render passes (nvn_mtl.m lay_decide / lay_continue / lay_route; MacNativeGames, MIT): five SetRenderTargets on faces 0-4 of a 16x16 cube,
// one draw each with its own colour, become one render pass whose draws reach their faces through the vertex amplification view mapping; face 5,
// inside no draw, keeps its contents. Not merged: a pass whose draws sample the cube being rendered (the separate passes had one face attached),
// and a pending clear on the first face does not clear the others. Negative control: DM_NVN_LAYER_MERGE=0 fails the "one render pass" checks.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, want, got) do { long long w=(want), g=(got); count++; printf("%-86s expected %-8llx → got %-8llx %s\n", name, (unsigned long long)w, (unsigned long long)g, w==g?"✓":"✗"); fail += w != g; } while (0)
typedef struct { uint8_t *p; size_t n; } chain;
static chain chain_new(void) { chain c={0}; if (posix_memalign((void **)&c.p,getpagesize(),65536)) abort(); memset(c.p,0,65536); mtl_pool_add(c.p,65536); return c; }
static void emit(chain *c, unsigned op, const void *a, size_t n) { size_t z=(8+n+7)&~7ull; op_hdr h={op,(uint32_t)z}; memcpy(c->p+c->n,&h,8); if(n) memcpy(c->p+c->n+8,a,n); c->n+=z; }
static uint8_t *g_mem; static uint64_t g_ubo; static prog_t g_pg, g_pg_s, g_pg_ps;
static uint32_t colour(int f) { return 0xff000000u | (uint32_t)(0x20 * (f + 1)) << 8 | (uint32_t)(0x30 + 0x10 * f); }   // RGBA8: r = 0x30 + 16 f, g = 32 (f + 1)
static tex_t cube(void) { static uint64_t s = 9400; tex_t t = {.serial = s++}; t.d.width = t.d.height = 16; t.d.depth = 1; t.d.samples = t.d.levels = 1; t.d.target = NVN_TEXTURE_TARGET_CUBEMAP; t.d.format = NVN_FORMAT_RGBA8; return t; }
static void set_face(chain *c, const tex_t *t, int f) {
    p_set_rt r = {.n = 1}; r.color[0] = t; r.has_cview[0] = 1; r.cview[0].set_layers = 1; r.cview[0].min_layer = (uint16_t)f; r.cview[0].nlayers = 1; emit(c, OP_SET_RT, &r, sizeof r);
}
static void fill(const tex_t *t) {   // every face grey, one submission
    chain c = chain_new(); p_clear_tex ct = {0}; ct.tex = t; ct.r = (NVNcopyRegion){0, 0, 0, 16, 16, 6}; ct.c.f[0] = ct.c.f[1] = ct.c.f[2] = 0x40 / 255.0f; ct.c.f[3] = 1; ct.mask = 15;
    emit(&c, OP_CLEAR_TEX, &ct, sizeof ct); emit(&c, OP_END, NULL, 0);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); uint64_t hh = (uint64_t)(uintptr_t)c.p; mtl_sub_index(&hh, 1); mtl_exec(c.p); mtl_wait(mtl_sub_commit(), 5000000000ull);
}
// One submission drawing faces [0, n) (face f in colour f), sampling program or not, optional clear before the first draw; the six faces' first pixels
static uint64_t faces(const tex_t *t, int n, const prog_t *pg, int clear0, uint32_t px[6]) {
    chain c = chain_new();
    for (int f = 0; f < n; f++) {
        set_face(&c, t, f);
        if (f == 0) { p_viewports vp = {.n = 1}; vp.v[0][2] = vp.v[0][3] = 16; emit(&c, OP_VIEWPORTS, &vp, sizeof vp); p_scissor sc = {0, 0, 16, 16}; emit(&c, OP_SCISSOR, &sc, sizeof sc);
            ds_st d = {0}; d.df = NVN_DEPTH_FUNC_ALWAYS; d.sf_f = d.sf_b = NVN_STENCIL_FUNC_ALWAYS; p_bind_state xs = {.kind = 5}; memcpy(xs.bytes, &d, sizeof d); emit(&c, OP_BIND_STATE, &xs, sizeof xs);
            p_bind_program bp = {pg, 3}; emit(&c, OP_BIND_PROGRAM, &bp, sizeof bp);
            if (pg == &g_pg_s) { p_bind_handles bh = {NVN_SHADER_STAGE_FRAGMENT, 0, 1}; bh.h[0] = 77 | (uint64_t)5 << 20; emit(&c, OP_BIND_TEX, &bh, sizeof bh); }
            if (clear0) { p_clear_color x = {.index = 0, .mask = 15, .rgba = {1, 1, 1, 1}}; emit(&c, OP_CLEAR_COLOR, &x, sizeof x); } }
        p_bind_buf ub = {NVN_SHADER_STAGE_FRAGMENT, 3, g_ubo + (uint64_t)f * 256, 256}; emit(&c, OP_BIND_UBO, &ub, sizeof ub);
        p_draw dw = {NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3, 0, 1}; emit(&c, OP_DRAW, &dw, sizeof dw);
    }
    emit(&c, OP_END, NULL, 0);
    uint64_t p0 = g_stat_pass;
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); uint64_t hh = (uint64_t)(uintptr_t)c.p; mtl_sub_index(&hh, 1); mtl_sub_snapshot(&hh, 1); mtl_exec(c.p);
    uint64_t np = g_stat_pass - p0;
    id<MTLBuffer> b = [g_dev newBufferWithLength:6 * 16 * 16 * 4 options:MTLResourceStorageModeShared]; res_add(b);
    for (int f = 0; f < 6; f++) [blit() copyFromTexture:tex_mtl(t) sourceSlice:f sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(16,16,1) toBuffer:b destinationOffset:(size_t)f * 1024 destinationBytesPerRow:64 destinationBytesPerImage:1024];
    mtl_wait(mtl_sub_commit(), 5000000000ull);
    for (int f = 0; f < 6; f++) memcpy(&px[f], (uint8_t *)b.contents + (size_t)f * 1024 + 8 * 64 + 8 * 4, 4);
    return np;
}
int main(int argc, char **argv) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); setenv("DM_NVN_TBDR", "0", 1); mtl_init();
    int expect_plain = argc > 1 && !strcmp(argv[1], "--off");   // DM_NVN_LAYER_MERGE=0 run: one pass per face
    if (posix_memalign((void **)&g_mem, getpagesize(), 65536)) abort(); memset(g_mem, 0, 65536); mtl_pool_add(g_mem, 65536); g_ubo = (uint64_t)(uintptr_t)(g_mem + 0x1000);
    for (int f = 0; f < 6; f++) { float c[4] = {(0x30 + 0x10 * f) / 255.0f, 0x20 * (f + 1) / 255.0f, 0, 1}; memcpy(g_mem + 0x1000 + f * 256, c, 16); }
    NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint id [[vertex_id]]) { float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; return float4(p[id], 0.5, 1); }\n"
        "struct VP { float4 p [[position]]; float ps [[point_size]]; };\n"
        "vertex VP vps(uint id [[vertex_id]]) { float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; VP o; o.p = float4(p[id], 0.5, 1); o.ps = 1; return o; }\n"
        "struct A { constant float4 *fp_c3 [[id(0)]]; };\n"
        "fragment float4 f(constant A &a [[buffer(0)]]) { return a.fp_c3[0]; }\n"
        "struct AS { constant float4 *fp_c3 [[id(0)]]; texturecube<float> fp_t0 [[id(1)]]; };\n"
        "fragment float4 fs_(constant AS &a [[buffer(0)]]) { return a.fp_c3[0]; }\n" options:nil error:&e];
    if (!l) { printf("%s\n", e.localizedDescription.UTF8String); return 1; }
    NSDictionary *c2 = @{@"tex": @[@(mtl_c2_tex_base()), @128], @"samp": @[@(mtl_c2_samp_base()), @128]};
    NSDictionary *j = @{@"route": @"B", @"stage": @"fs", @"c2": c2, @"bindings": @[@{@"msl_name": @"fp_c3", @"kind": @"cbuf", @"reg": @3, @"arg_id": @0}], @"drv_reads": @{}};
    NSDictionary *js = @{@"route": @"B", @"stage": @"fs", @"c2": c2, @"bindings": @[@{@"msl_name": @"fp_c3", @"kind": @"cbuf", @"reg": @3, @"arg_id": @0},
        @{@"msl_name": @"fp_t0", @"kind": @"tex", @"reg": @0, @"arg_id": @1, @"msl_type": @"texturecube<float>"}], @"drv_reads": @{}};
    nvn_refl rf, rfs; char err[256] = "";
    if (nvn_refl_from_json(j, &rf, err, sizeof err) || nvn_refl_from_json(js, &rfs, err, sizeof err)) { printf("reflection: %s\n", err); return 1; }
    const prog_t *pgs[2] = {&g_pg, &g_pg_s}; const nvn_refl *rfa[2] = {&rf, &rfs}; NSString *fn[2] = {@"f", @"fs_"};
    for (int k = 0; k < 2; k++) { ((prog_t *)pgs[k])->serial = 8960 + k; NvProg *p = [NvProg new]; p->sh[0] = [NvShader new]; p->sh[0]->fn = [l newFunctionWithName:@"v"];
        p->sh[1] = [NvShader new]; p->sh[1]->stage = 1; p->sh[1]->fn = [l newFunctionWithName:fn[k]]; p->sh[1]->rf = *rfa[k]; p->sh[1]->ae = [p->sh[1]->fn newArgumentEncoderWithBufferIndex:0]; serial_put(pgs[k]->serial, p); }
    { g_pg_ps.serial = 8962; NvProg *p = [NvProg new]; p->sh[0] = [NvShader new]; p->sh[0]->fn = [l newFunctionWithName:@"vps"];
      p->sh[1] = [NvShader new]; p->sh[1]->stage = 1; p->sh[1]->fn = [l newFunctionWithName:@"f"]; p->sh[1]->rf = rf; p->sh[1]->ae = [p->sh[1]->fn newArgumentEncoderWithBufferIndex:0]; serial_put(g_pg_ps.serial, p); }
    uint32_t px[6]; uint64_t np;
    // 1. faces 0-4 in one pass, face 5 untouched
    { tex_t t = cube(); fill(&t); uint64_t m0 = g_lay.merges;
      np = faces(&t, 5, &g_pg, 0, px);
      int ok = 1; for (int f = 0; f < 5; f++) ok &= px[f] == colour(f);
      EXPECT("faces 0-4 each in its own colour", 1, ok);
      EXPECT("face 5, drawn by none, keeps its grey", 0xff404040, px[5]);
      EXPECT(expect_plain ? "DM_NVN_LAYER_MERGE=0: five render passes" : "one render pass for the five faces [DM_NVN_LAYER_MERGE=0 fails]", expect_plain ? 5 : 1, np);
      if (!expect_plain) EXPECT("... four SetRenderTargets went on in it", 4, (long long)(g_lay.merges - m0)); }
    // 1b. a vertex shader that writes point size (Tears of the Kingdom has some): its layered pipeline builds and the faces are drawn
    { tex_t t = cube(); fill(&t);
      np = faces(&t, 3, &g_pg_ps, 0, px);
      EXPECT("vertex shader writing point size: faces 0-2 drawn", 1, px[0] == colour(0) && px[1] == colour(1) && px[2] == colour(2));
      EXPECT(expect_plain ? "... DM_NVN_LAYER_MERGE=0: three passes" : "... in one render pass", expect_plain ? 3 : 1, np); }
    // 2. the draws sample the cube being rendered (texture ID 77 = this cube, no view): not merged
    { tex_t t = cube(); fill(&t); mtl_reg_tex(77, &t, NULL); samp_par sp = {0}; mtl_reg_samp(5, &sp); uint64_t lp0 = g_lay.passes;
      np = faces(&t, 5, &g_pg_s, 0, px);
      EXPECT("sampling the target: no layered pass opened, not even by the first draw", 0, (long long)(g_lay.passes - lp0));
      int ok = 1; for (int f = 0; f < 5; f++) ok &= px[f] == colour(f);
      EXPECT("sampling the target: faces still right", 1, ok);
      EXPECT("sampling the target: one pass per face (not merged)", 5, np); }
    // 3. a full clear pending on face 0 before its draw: the pass opens plain (a layered load action would clear every face of the range)
    { tex_t t = cube(); fill(&t);
      np = faces(&t, 1, &g_pg, 1, px);
      EXPECT("clear then draw on face 0: face 0 drawn", colour(0), px[0]);
      EXPECT("... face 1 keeps its grey", 0xff404040, px[1]); }
    { tex_t t = cube(); fill(&t);
      chain c = chain_new(); set_face(&c, &t, 0);
      p_viewports vp = {.n = 1}; vp.v[0][2] = vp.v[0][3] = 16; emit(&c, OP_VIEWPORTS, &vp, sizeof vp); p_scissor sc = {0, 0, 16, 16}; emit(&c, OP_SCISSOR, &sc, sizeof sc);
      ds_st d = {0}; d.df = NVN_DEPTH_FUNC_ALWAYS; d.sf_f = d.sf_b = NVN_STENCIL_FUNC_ALWAYS; p_bind_state xs = {.kind = 5}; memcpy(xs.bytes, &d, sizeof d); emit(&c, OP_BIND_STATE, &xs, sizeof xs);
      p_bind_program bp = {&g_pg, 3}; emit(&c, OP_BIND_PROGRAM, &bp, sizeof bp);
      p_clear_color x = {.index = 0, .mask = 15, .rgba = {1, 1, 1, 1}}; emit(&c, OP_CLEAR_COLOR, &x, sizeof x);
      p_bind_buf ub = {NVN_SHADER_STAGE_FRAGMENT, 3, g_ubo, 256}; emit(&c, OP_BIND_UBO, &ub, sizeof ub);
      p_scissor half = {0, 0, 8, 16}; emit(&c, OP_SCISSOR, &half, sizeof half);
      p_draw dw = {NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3, 0, 1}; emit(&c, OP_DRAW, &dw, sizeof dw);
      for (int f = 1; f < 4; f++) { set_face(&c, &t, f); p_bind_buf u2 = {NVN_SHADER_STAGE_FRAGMENT, 3, g_ubo + (uint64_t)f * 256, 256}; emit(&c, OP_BIND_UBO, &u2, sizeof u2); emit(&c, OP_DRAW, &dw, sizeof dw); }
      emit(&c, OP_END, NULL, 0);
      state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); uint64_t hh = (uint64_t)(uintptr_t)c.p; mtl_sub_index(&hh, 1); mtl_sub_snapshot(&hh, 1); mtl_exec(c.p);
      id<MTLBuffer> b = [g_dev newBufferWithLength:6 * 1024 options:MTLResourceStorageModeShared]; res_add(b);
      for (int f = 0; f < 6; f++) [blit() copyFromTexture:tex_mtl(&t) sourceSlice:f sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(16,16,1) toBuffer:b destinationOffset:(size_t)f * 1024 destinationBytesPerRow:64 destinationBytesPerImage:1024];
      mtl_wait(mtl_sub_commit(), 5000000000ull);
      uint32_t r0, g1; memcpy(&r0, (uint8_t *)b.contents + 8 * 64 + 12 * 4, 4); memcpy(&g1, (uint8_t *)b.contents + 1024 + 8 * 64 + 12 * 4, 4);
      EXPECT("cleared face 0, right half (outside the draws' scissor): white", 0xffffffff, r0);
      EXPECT("faces 1-3 drawn in the left half only: face 1's right half keeps its grey (the clear did not reach it)", 0xff404040, g1); }
    printf("== %d checks, %d failed ==\n", count, fail); return fail != 0;
} }
