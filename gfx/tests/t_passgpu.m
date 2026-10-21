// Per-pass GPU time (DM_NVN_PASSGPU, nvn_mtl.m pg_*; plan item 49, after upstream 44a6770's timestamps, jhaizhou-ops/d2r-mobile, MIT), on the GPU
// through the production replay. One submission: a light pass (one triangle on 64x64), a heavy pass (a fragment loop on 512x512), the light one
// again and a dispatch. Each gets a row, R R R C, with its index in the frame, its pass number and size; its start is at or before its end; the
// heavy pass's increment is over four times each other one's and 90 % of their sum (spans overlap: on Metal 3 the light pass after the heavy one
// spans 13 ms, its increment is 0); the increments add up to no more than the span from the first start to the last end.
// A second submission writes its own rows (the ring's next heap, nothing left over from the first). Negative control: -DDM_TEST_PG_NO_END (no
// end timestamp written) leaves no row.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, ok) do { count++; int ok_ = !!(ok); printf("%-96s %s\n", name, ok_ ? "✓" : "✗"); fail += !ok_; } while (0)
typedef struct { uint8_t *p; size_t n; } chain;
static chain chain_new(void) { chain c = {0}; if (posix_memalign((void **)&c.p, getpagesize(), 65536)) abort(); memset(c.p, 0, 65536); mtl_pool_add(c.p, 65536); return c; }
static void emit(chain *c, unsigned op, const void *a, size_t n) { size_t z = (8 + n + 7) & ~7ull; op_hdr h = {op, (uint32_t)z}; memcpy(c->p + c->n, &h, 8); if (n) memcpy(c->p + c->n + 8, a, n); c->n += z; }
static tex_t tex(int w) { static uint64_t s = 9950; tex_t t = {.serial = s++}; t.d.width = t.d.height = (uint32_t)w; t.d.depth = t.d.samples = t.d.levels = 1; t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = NVN_FORMAT_RGBA8; return t; }
static void pass(chain *c, const tex_t *t, prog_t *p) {
    p_set_rt r = {.n = 1}; r.color[0] = t; emit(c, OP_SET_RT, &r, sizeof r);
    int w = (int)t->d.width; p_viewports v = {.n = 1}; v.v[0][2] = v.v[0][3] = (float)w; emit(c, OP_VIEWPORTS, &v, sizeof v); p_scissor sc = {0, 0, w, w}; emit(c, OP_SCISSOR, &sc, sizeof sc);
    p_clear_color k = {.index = 0, .mask = 15}; emit(c, OP_CLEAR_COLOR, &k, sizeof k);
    p_bind_program b = {p, 3}; emit(c, OP_BIND_PROGRAM, &b, sizeof b);
    p_draw d = {NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3}; emit(c, OP_DRAW, &d, sizeof d);
}
typedef struct { unsigned long long frame, pass, t0, t1; int idx, w, h, draws; char kind; double ms, inc; } row;
static int rows(const char *path, row *out, int max) {   // the rows written so far
    FILE *f = fopen(path, "r"); if (!f) return 0;
    char line[512]; int n = 0; if (!fgets(line, sizeof line, f)) { fclose(f); return 0; }   // header
    while (n < max && fgets(line, sizeof line, f)) {
        row r = {0}; char load[16]; unsigned f0, df;
        if (sscanf(line, "%llu\t%d\t%c\t%lf\t%lf\t%d\t%d\t%u\t%u\t%15s\t%d\t%llu\t%llu\t%llu", &r.frame, &r.idx, &r.kind, &r.ms, &r.inc, &r.w, &r.h, &f0, &df, load, &r.draws, &r.t0, &r.t1, &r.pass) == 14) out[n++] = r;
    }
    fclose(f); return n;
}
static int wait_rows(const char *path, int want, row *out, int max) { int n = 0; for (int i = 0; i < 400 && (n = rows(path, out, max)) < want; i++) usleep(5000); return n; }
static void submit(chain *c) {
    emit(c, OP_END, NULL, 0); state_reset(); memset(&R, 0, sizeof R);
    mtl_sub_begin(); uint64_t hh = (uint64_t)c->p; mtl_sub_index(&hh, 1); mtl_sub_snapshot(&hh, 1); mtl_exec(c->p);
    if (!mtl_wait(mtl_sub_commit(), 10000000000ull) || mtl_last_commit_error()) { printf("GPU did not complete\n"); abort(); }
}

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    char path[512]; snprintf(path, sizeof path, "%s/t_passgpu_%d.tsv", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", getpid());
    setenv("DM_NVN_PASSGPU", path, 1); setenv("DM_NVN_TBDR", "0", 1); setenv("DM_NVN_CHUNK_DRAWS", "0", 1); mtl_init();
    NSError *e = nil;
    id<MTLLibrary> l = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint n [[vertex_id]]) { float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; return float4(p[n], 0, 1); }\n"
        "fragment float4 light() { return float4(0.5); }\n"
        "fragment float4 heavy(float4 pos [[position]]) { float a = pos.x * 0.001; for (int i = 0; i < 3000; i++) a = sin(a) * 1.0001 + 0.0001; return float4(a); }\n"
        "struct A { device uint4 *cp_s0 [[id(0)]]; };\n"
        "kernel void k(constant A &a [[buffer(0)]], uint g [[thread_position_in_grid]]) { a.cp_s0[g] = uint4(g); }\n" options:nil error:&e];
    if (!l) { printf("%s\n", e.localizedDescription.UTF8String); return 2; }
    static prog_t pl = {.serial = 9960}, ph = {.serial = 9961}, pc = {.serial = 9962}; static NvProg *keep[3];
    for (int i = 0; i < 2; i++) { NvProg *p = [NvProg new]; p->sh[0] = [NvShader new]; p->sh[0]->fn = [l newFunctionWithName:@"v"];
        p->sh[1] = [NvShader new]; p->sh[1]->stage = 1; p->sh[1]->fn = [l newFunctionWithName:i ? @"heavy" : @"light"]; serial_put(i ? ph.serial : pl.serial, p); keep[i] = p; }
    NSDictionary *j = @{@"route": @"B", @"stage": @"cs", @"c2": @{@"tex": @[@(mtl_c2_tex_base()), @128], @"samp": @[@(mtl_c2_samp_base()), @128]},
        @"bindings": @[@{@"msl_name": @"cp_s0", @"kind": @"sbuf", @"arg_id": @0, @"reg": @0, @"rw": @YES}], @"drv_reads": @{}, @"threadgroup_size": @[@64, @1, @1]};
    nvn_refl rf; char err[256] = ""; if (nvn_refl_from_json(j, &rf, err, sizeof err)) { printf("json: %s\n", err); return 2; }
    { NvProg *p = [NvProg new]; p->sh[5] = [NvShader new]; p->sh[5]->stage = 5; p->sh[5]->fn = [l newFunctionWithName:@"k"]; p->sh[5]->rf = rf;
      p->sh[5]->ae = [p->sh[5]->fn newArgumentEncoderWithBufferIndex:0]; serial_put(pc.serial, p); keep[2] = p; }
    uint8_t *mem; if (posix_memalign((void **)&mem, getpagesize(), 65536)) abort(); memset(mem, 0, 65536); mtl_pool_add(mem, 65536);

    tex_t A = tex(64), B = tex(512), C = tex(64);
    chain c = chain_new(); uint64_t pass0 = g_stat_pass;
    pass(&c, &A, &pl); pass(&c, &B, &ph); pass(&c, &C, &pl);
    p_bind_buf sb = {NVN_SHADER_STAGE_COMPUTE, 0, (uint64_t)(uintptr_t)mem, 4096}; emit(&c, OP_BIND_SSBO, &sb, sizeof sb);
    p_bind_program bp = {&pc, NVN_SHADER_STAGE_COMPUTE_BIT}; emit(&c, OP_BIND_PROGRAM, &bp, sizeof bp);
    p_dispatch d = {4, 1, 1, 0}; emit(&c, OP_DISPATCH, &d, sizeof d);
    submit(&c);
    row r[16]; int n = wait_rows(path, 4, r, 16);
    printf("rows: %d\n", n); for (int i = 0; i < n; i++) printf("  %c idx %d pass %llu %dx%d draws %d: %.4f ms, increment %.4f ms\n", r[i].kind, r[i].idx, r[i].pass, r[i].w, r[i].h, r[i].draws, r[i].ms, r[i].inc);
    EXPECT("four rows: three render passes and a dispatch", n == 4 && r[0].kind == 'R' && r[1].kind == 'R' && r[2].kind == 'R' && r[3].kind == 'C');
    if (n < 4) { printf("== %d checks, %d failed ==\n", count, fail); unlink(path); return 1; }
    EXPECT("indexes 0-3 in one frame", r[0].idx == 0 && r[1].idx == 1 && r[2].idx == 2 && r[3].idx == 3 && r[0].frame == r[3].frame);
    EXPECT("pass numbers of the three render passes, in order", r[0].pass == pass0 + 1 && r[1].pass == pass0 + 2 && r[2].pass == pass0 + 3);
    EXPECT("sizes 64, 512, 64 and one draw each", r[0].w == 64 && r[1].w == 512 && r[1].h == 512 && r[2].w == 64 && r[0].draws == 1 && r[1].draws == 1);
    int ord = 1; for (int i = 0; i < 4; i++) ord &= r[i].t0 && r[i].t1 >= r[i].t0;
    EXPECT("every start is set and at or before its end", ord);
    double inc = 0; unsigned long long lo = r[0].t0, hi = 0; for (int i = 0; i < 4; i++) { inc += r[i].inc; if (r[i].t0 < lo) lo = r[i].t0; if (r[i].t1 > hi) hi = r[i].t1; }
    printf("  increments: heavy %.4f ms, the others %.4f / %.4f / %.4f ms, all %.4f ms\n", r[1].inc, r[0].inc, r[2].inc, r[3].inc, inc);
    EXPECT("the heavy pass's increment: over four times each other one's and 90 % of all", r[1].inc > 4 * r[0].inc && r[1].inc > 4 * r[2].inc && r[1].inc > 4 * r[3].inc
           && r[1].inc >= 0.9 * inc && r[1].inc > 0.2);
    EXPECT("the increments add up to no more than the first start to the last end", inc <= (hi - lo) / 1e6 + 1e-3);
    chain c2 = chain_new(); pass(&c2, &A, &pl); submit(&c2);
    row r2[16]; int n2 = wait_rows(path, 5, r2, 16);
    EXPECT("a second submission: one more row, its own pass", n2 == 5 && r2[4].kind == 'R' && r2[4].pass == pass0 + 4 && r2[4].t0 >= r[3].t0);
    unlink(path);
    printf("== %d checks, %d failed ==\n", count, fail); return fail != 0;
} }
