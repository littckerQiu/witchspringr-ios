// Inline uniform updates without ending the render pass (nvn_mtl.m upd_log / upd_shadow / upd_flush; MacNativeGames, MIT). One submission draws the
// left half reading a uniform colour, updates it inline, draws the right half: the left half keeps the old colour, the right half has the new one, in
// one render pass, and memory holds the update once the submission is done. Also: a storage buffer over the updated range writes the updates first,
// a depth-tested draw after an update keeps the depth attachment (ds_scan goes on past it), a replay-time read of the range sees the update.
// Negative control: DM_NVN_UB_RENAME=0 fails the "one render pass" checks (each update ended the pass); with --expect-split it checks the old path.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, want, got) do { long long w=(want), g=(got); count++; printf("%-92s expected %-10llx → got %-10llx %s\n", name, (unsigned long long)w, (unsigned long long)g, w==g?"✓":"✗"); fail += w != g; } while (0)
typedef struct { uint8_t *p; size_t n; } chain;
static chain chain_new(void) { chain c={0}; if (posix_memalign((void **)&c.p,getpagesize(),65536)) abort(); memset(c.p,0,65536); mtl_pool_add(c.p,65536); return c; }
static void emit(chain *c, unsigned op, const void *a, size_t n) { size_t z=(8+n+7)&~7ull; op_hdr h={op,(uint32_t)z}; memcpy(c->p+c->n,&h,8); if(n) memcpy(c->p+c->n+8,a,n); c->n+=z; }
static tex_t tex(unsigned w, int fmt) { static uint64_t s=9600; tex_t t={.serial=s++}; t.d.width=t.d.height=w; t.d.depth=t.d.samples=t.d.levels=1; t.d.target=NVN_TEXTURE_TARGET_2D; t.d.format=fmt; return t; }
static void ds(chain *c, int dt, int df) { ds_st d = {0}; d.dt = dt; d.df = df; d.sf_f = d.sf_b = NVN_STENCIL_FUNC_ALWAYS; p_bind_state xs = {.kind = 5}; memcpy(xs.bytes, &d, sizeof d); emit(c, OP_BIND_STATE, &xs, sizeof xs); }
static void scissor(chain *c, int x, int w) { p_scissor sc = {x, 0, w, 8}; emit(c, OP_SCISSOR, &sc, sizeof sc); }
static void update(chain *c, uint64_t dst, const float v[4]) { uint8_t up[16 + 16]; uint64_t len = 16; memcpy(up, &dst, 8); memcpy(up + 8, &len, 8); memcpy(up + 16, v, 16); emit(c, OP_UPDATE_UB, up, sizeof up); }
static uint8_t *g_mem; static prog_t g_pg, g_pg2, g_pg3; static uint64_t g_ubo;
static const float RED[4] = {1, 0, 0, 1}, GREEN[4] = {0, 1, 0, 1}, BLUE[4] = {0, 0, 1, 1};
// One submission on an 8x8 RGBA8 target (and a depth target if depth), returns the pixels at (1, 4) and (6, 4) and the render passes it opened
static void run(chain *c, const tex_t *t, uint32_t *left, uint32_t *right, uint64_t *passes) {
    emit(c, OP_END, NULL, 0);
    uint64_t p0 = g_stat_pass;
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); uint64_t hh = (uint64_t)c->p; mtl_sub_index(&hh, 1); mtl_sub_snapshot(&hh, 1); mtl_exec(c->p);
    *passes = g_stat_pass - p0;
    id<MTLBuffer> b = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; res_add(b);
    [blit() copyFromTexture:tex_mtl(t) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];
    mtl_wait(mtl_sub_commit(), 5000000000ull);
    memcpy(left, (uint8_t *)b.contents + 4 * 32 + 1 * 4, 4); memcpy(right, (uint8_t *)b.contents + 4 * 32 + 6 * 4, 4);
}
static void begin_z(chain *c, const tex_t *t, const tex_t *d, int clear_d) {
    p_set_rt r = {.n = 1}; r.color[0] = t; r.depth = d; emit(c, OP_SET_RT, &r, sizeof r);
    p_viewports v = {.n = 1}; v.v[0][2] = v.v[0][3] = 8; emit(c, OP_VIEWPORTS, &v, sizeof v); scissor(c, 0, 8);
    p_clear_color x = {.index = 0, .mask = 15, .rgba = {0, 0, 0, 0}}; emit(c, OP_CLEAR_COLOR, &x, sizeof x);
    if (d && clear_d) { p_clear_ds z = {0.0f, 1, 0, 0}; emit(c, OP_CLEAR_DS, &z, sizeof z); }
    ds(c, 0, NVN_DEPTH_FUNC_ALWAYS);
    p_bind_program bp = {&g_pg, 3}; emit(c, OP_BIND_PROGRAM, &bp, sizeof bp);
    p_bind_buf ub = {NVN_SHADER_STAGE_FRAGMENT, 3, g_ubo, 256}; emit(c, OP_BIND_UBO, &ub, sizeof ub);
}
static void begin(chain *c, const tex_t *t, const tex_t *d) { begin_z(c, t, d, 1); }
static void draw3(chain *c) { p_draw dw = {NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3, 0, 1}; emit(c, OP_DRAW, &dw, sizeof dw); }
int main(int argc, char **argv) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); mtl_init();
    if (posix_memalign((void **)&g_mem, getpagesize(), 65536)) abort(); memset(g_mem, 0, 65536); mtl_pool_add(g_mem, 65536);
    g_ubo = (uint64_t)(uintptr_t)(g_mem + 0x1000);
    NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint id [[vertex_id]]) { float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; return float4(p[id], 0.5, 1); }\n"
        "vertex float4 v2(uint id [[vertex_id]]) { float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; return float4(p[id], 0.5, 1.0); }\n"
        "struct A { constant float4 *fp_c3 [[id(0)]]; };\n"
        "fragment float4 f(constant A &a [[buffer(0)]]) { return a.fp_c3[0]; }\n"
        "struct A3 { device float4 *fp_s0 [[id(0)]]; };\n"
        "fragment float4 f3(constant A3 &a [[buffer(0)]]) { return a.fp_s0[0]; }\n" options:nil error:&e];
    if (!l) { printf("%s\n", e.localizedDescription.UTF8String); return 1; }
    NSDictionary *j = @{@"route": @"B", @"stage": @"fs", @"c2": @{@"tex": @[@(mtl_c2_tex_base()), @128], @"samp": @[@(mtl_c2_samp_base()), @128]},
        @"bindings": @[@{@"msl_name": @"fp_c3", @"kind": @"cbuf", @"reg": @3, @"arg_id": @0}], @"drv_reads": @{}};
    nvn_refl rf; char err[256] = ""; if (nvn_refl_from_json(j, &rf, err, sizeof err)) { printf("reflection: %s\n", err); return 1; }
    g_pg.serial = 8900; NvProg *p = [NvProg new]; p->sh[0] = [NvShader new]; p->sh[0]->fn = [l newFunctionWithName:@"v"];
    p->sh[1] = [NvShader new]; p->sh[1]->stage = 1; p->sh[1]->fn = [l newFunctionWithName:@"f"]; p->sh[1]->rf = rf; p->sh[1]->ae = [p->sh[1]->fn newArgumentEncoderWithBufferIndex:0];
    serial_put(g_pg.serial, p);
    // a second program (same functions, another serial and vertex layout key) so that case 0 needs two new pipelines
    g_pg2.serial = 8901; NvProg *p2 = [NvProg new]; p2->sh[0] = [NvShader new]; p2->sh[0]->fn = [l newFunctionWithName:@"v2"];
    p2->sh[1] = [NvShader new]; p2->sh[1]->stage = 1; p2->sh[1]->fn = p->sh[1]->fn; p2->sh[1]->rf = rf; p2->sh[1]->ae = [p2->sh[1]->fn newArgumentEncoderWithBufferIndex:0];
    serial_put(g_pg2.serial, p2);
    // a program whose fragment shader reads the colour from storage buffer slot 0 (case 3)
    NSDictionary *j3 = @{@"route": @"B", @"stage": @"fs", @"c2": @{@"tex": @[@(mtl_c2_tex_base()), @128], @"samp": @[@(mtl_c2_samp_base()), @128]},
        @"bindings": @[@{@"msl_name": @"fp_s0", @"kind": @"sbuf", @"reg": @0, @"arg_id": @0, @"rw": @NO}], @"drv_reads": @{}};
    nvn_refl rf3; if (nvn_refl_from_json(j3, &rf3, err, sizeof err)) { printf("reflection: %s\n", err); return 1; }
    g_pg3.serial = 8902; NvProg *p3 = [NvProg new]; p3->sh[0] = [NvShader new]; p3->sh[0]->fn = p->sh[0]->fn;
    p3->sh[1] = [NvShader new]; p3->sh[1]->stage = 1; p3->sh[1]->fn = [l newFunctionWithName:@"f3"]; p3->sh[1]->rf = rf3; p3->sh[1]->ae = [p3->sh[1]->fn newArgumentEncoderWithBufferIndex:0];
    serial_put(g_pg3.serial, p3);
    const uint32_t R_ = 0xff0000ff, G_ = 0xff00ff00, B_ = 0xffff0000;
    int rename = ub_rename_on(), passes = argc > 1 && !strcmp(argv[1], "--expect-split") ? 2 : 1;   // --expect-split: DM_NVN_UB_RENAME=0 run, each update ends the pass
    // 0. The first draw of a new pipeline keeps its scissor: the parallel precompile walks the rest of the submission through state_op, which sets the
    //    scissor too, and put back only the draw state (that draw took the scissor of the last draw walked over: here the right half)
    { tex_t t = tex(8, NVN_FORMAT_RGBA8); chain c = chain_new(); memcpy((void *)(uintptr_t)g_ubo, RED, 16);
      begin(&c, &t, NULL); scissor(&c, 0, 4); draw3(&c); scissor(&c, 4, 4); emit(&c, OP_BIND_PROGRAM, &(p_bind_program){&g_pg2, 3}, sizeof(p_bind_program)); draw3(&c);
      uint32_t lp, rp; uint64_t np; run(&c, &t, &lp, &rp, &np);
      EXPECT("new pipelines: the first draw keeps its scissor (left red)", R_, lp);
      EXPECT("... and the second draws the right half (red)", R_, rp); }
    // 1. draw left (red), update to green, draw right
    { tex_t t = tex(8, NVN_FORMAT_RGBA8); chain c = chain_new(); memcpy((void *)(uintptr_t)g_ubo, RED, 16);
      begin(&c, &t, NULL); scissor(&c, 0, 4); draw3(&c); update(&c, g_ubo, GREEN); scissor(&c, 4, 4); draw3(&c);
      uint32_t lp, rp; uint64_t np; run(&c, &t, &lp, &rp, &np);
      EXPECT("draw before the update reads the old colour (red)", R_, lp);
      EXPECT("draw after the update reads the new colour (green)", G_, rp);
      EXPECT("one render pass for both draws [DM_NVN_UB_RENAME=0 fails; with --expect-split: two]", passes, np);
      float m[4]; memcpy(m, (const void *)(uintptr_t)g_ubo, 16);
      EXPECT("memory holds the update after the submission", 1, !memcmp(m, GREEN, 16)); }
    // 2. two updates of the same range between draws: the newest wins; a third draw reads it too
    { tex_t t = tex(8, NVN_FORMAT_RGBA8); chain c = chain_new(); memcpy((void *)(uintptr_t)g_ubo, RED, 16);
      begin(&c, &t, NULL); scissor(&c, 0, 4); draw3(&c); update(&c, g_ubo, GREEN); update(&c, g_ubo, BLUE); scissor(&c, 4, 4); draw3(&c);
      uint32_t lp, rp; uint64_t np; run(&c, &t, &lp, &rp, &np);
      EXPECT("two updates: the left draw still red", R_, lp);
      EXPECT("two updates: the right draw reads the newest (blue)", B_, rp); }
    // 2b. updates written to memory in the middle (a buffer copy elsewhere ends the pass and writes them), then the range updated again: the snapshot is
    //     still there, so the next draw gets a private copy with both updates and nothing is written before it
    { tex_t t = tex(8, NVN_FORMAT_RGBA8); chain c = chain_new(); memcpy((void *)(uintptr_t)g_ubo, RED, 16);
      uint64_t g0 = g_ren_guard, f0 = g_ren_flushes;
      begin(&c, &t, NULL); scissor(&c, 0, 4); draw3(&c); update(&c, g_ubo, GREEN);
      uint64_t cp[3] = {(uint64_t)(uintptr_t)(g_mem + 0x3000), (uint64_t)(uintptr_t)(g_mem + 0x3100), 64}; emit(&c, OP_COPY_B2B, cp, sizeof cp);
      float half[4] = {0, 0, 1, 1}; uint8_t up[16 + 8]; uint64_t dst = g_ubo + 8, len = 8; memcpy(up, &dst, 8); memcpy(up + 8, &len, 8); memcpy(up + 16, half + 2, 8); emit(&c, OP_UPDATE_UB, up, sizeof up);   // b, a = 1, 1
      scissor(&c, 4, 4); draw3(&c);
      uint32_t lp, rp; uint64_t np; run(&c, &t, &lp, &rp, &np);
      EXPECT("written in the middle, updated again: left red", R_, lp);
      EXPECT("... right: green's r, g with the second update's b, a (0, 1, 1, 1)", 0xffffff00, rp);
      if (rename) { EXPECT("... nothing written before that draw (the snapshot stayed)", 0, g_ren_guard - g0);
                    EXPECT("... written twice: by the copy and at the end", 2, g_ren_flushes - f0); } }
    // 3. a storage buffer over the updated range: the updates are written before that draw, which reads them from memory (green)
    { tex_t t = tex(8, NVN_FORMAT_RGBA8); chain c = chain_new(); memcpy((void *)(uintptr_t)g_ubo, RED, 16);
      uint64_t g0 = g_ren_guard;
      begin(&c, &t, NULL); scissor(&c, 0, 4); draw3(&c); update(&c, g_ubo, GREEN);
      emit(&c, OP_BIND_PROGRAM, &(p_bind_program){&g_pg3, 3}, sizeof(p_bind_program));
      p_bind_buf sb = {NVN_SHADER_STAGE_FRAGMENT, 0, g_ubo, 256}; emit(&c, OP_BIND_SSBO, &sb, sizeof sb);
      scissor(&c, 4, 4); draw3(&c);
      uint32_t lp, rp; uint64_t np; run(&c, &t, &lp, &rp, &np);
      EXPECT("storage buffer over an updated range: left red", R_, lp);
      EXPECT("... the storage read sees the update (green)", G_, rp);
      if (rename) EXPECT("... the updates were written before that draw", 1, g_ren_guard - g0); }
    // 4. depth: a submission clears the depth target to 0; the next one (no depth clear: depth comes only from the lookahead) draws the left half testing
    //    nothing, updates, then draws the right half testing LESS: rejected only if the pass kept its depth attachment past the update (ds_scan)
    { tex_t t = tex(8, NVN_FORMAT_RGBA8), d = tex(8, NVN_FORMAT_DEPTH32F); memcpy((void *)(uintptr_t)g_ubo, RED, 16);
      chain c0 = chain_new(); begin(&c0, &t, &d); uint32_t l0, r0; uint64_t n0; run(&c0, &t, &l0, &r0, &n0);
      chain c = chain_new(); begin_z(&c, &t, &d, 0); scissor(&c, 0, 4); draw3(&c); update(&c, g_ubo, GREEN); ds(&c, 1, NVN_DEPTH_FUNC_LESS); scissor(&c, 4, 4); draw3(&c);
      uint32_t lp, rp; uint64_t np; run(&c, &t, &lp, &rp, &np);
      EXPECT("depth: left drawn red", R_, lp);
      EXPECT("depth: the depth-tested draw after the update is rejected (depth attached)", 0, rp);
      EXPECT("depth: one render pass [DM_NVN_UB_RENAME=0 fails; with --expect-split: two]", passes, np); }
    // 5. replay-time read (pend_read, as for storage buffer addresses in uniform data): sees the update logged before it
    if (rename) { memcpy((void *)(uintptr_t)g_ubo, RED, 16);
      chain c = chain_new(); p_bind_buf ub = {NVN_SHADER_STAGE_FRAGMENT, 3, g_ubo, 256}; emit(&c, OP_BIND_UBO, &ub, sizeof ub); emit(&c, OP_END, NULL, 0);
      state_reset(); mtl_sub_begin(); uint64_t hh = (uint64_t)c.p; mtl_sub_snapshot(&hh, 1);
      float out[4]; pend_read(g_ubo, out, 16); int before = !memcmp(out, RED, 16);
      mtl_sub_update(GREEN, g_ubo, 16); pend_read(g_ubo, out, 16); int after = !memcmp(out, GREEN, 16);
      float f1; uint16_t ref = 3 << 8 | 0 << 2 | 1; S.ubo[1][3] = ub; int okf = ubo_float(1, ref, &f1);
      mtl_wait(mtl_sub_commit(), 5000000000ull);
      EXPECT("replay-time read before the update: red", 1, before);
      EXPECT("replay-time read after the update: green (the snapshot with the update over it)", 1, after);
      EXPECT("ubo_float after the update: green's g = 1", 1, okf && f1 == 1.0f); }
    printf("== %d checks, %d failed ==\n", count, fail); return fail != 0;
} }
