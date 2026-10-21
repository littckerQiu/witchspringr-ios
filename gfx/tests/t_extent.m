// The part of a render pass its draws reach (DM_NVN_COUNTS=1, nvn_mtl.m cnt_extent; plan item 46, which limits the render area only if a game
// draws such passes: Tears of the Kingdom and manosaba do not), on the GPU through the production replay, one pass on an 8x8 target per case:
//   whole        a full-screen draw: not a part
//   scissor      a scissor 4 wide: a part, 32 pixels outside
//   viewport     a 4x4 viewport under a full scissor: a part, 48 pixels outside
//   far corner   a 4x4 scissor at (4, 4) reaches the right and bottom edges: not a part (a render area starts at the origin)
//   two draws    a 4x4 draw, then a full one: not a part
//   clear first  a clear on load, then a 4x4 draw: counted apart (the render area would leave the clear outside it undone)
//   clear quad   a 4x4 draw, then a full clear inside the pass: not a part
// After LASRecomp 59a7507 (Peiikai, MIT: its render area for the part dynamic resolution draws). Negative control: -DDM_TEST_EXTENT_BROKEN (the
// viewport and clear quads left out) fails viewport and clear quad.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, want, got) do { uint64_t w = (want), g = (got); count++; printf("%-70s expected %-4llu → got %-4llu %s\n", name, (unsigned long long)w, (unsigned long long)g, w == g ? "✓" : "✗"); fail += w != g; } while (0)
typedef struct { uint8_t *p; size_t n; } chain;
static chain chain_new(void) { chain c = {0}; if (posix_memalign((void **)&c.p, getpagesize(), 65536)) abort(); memset(c.p, 0, 65536); mtl_pool_add(c.p, 65536); return c; }
static void emit(chain *c, unsigned op, const void *a, size_t n) { size_t z = (8 + n + 7) & ~7ull; op_hdr h = {op, (uint32_t)z}; memcpy(c->p + c->n, &h, 8); if (n) memcpy(c->p + c->n + 8, a, n); c->n += z; }
static tex_t tex(void) { static uint64_t s = 9800; tex_t t = {.serial = s++}; t.d.width = t.d.height = 8; t.d.depth = t.d.samples = t.d.levels = 1; t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = NVN_FORMAT_RGBA8; return t; }
static void viewport(chain *c, int x, int y, int w, int h) { p_viewports v = {.n = 1}; v.v[0][0] = x; v.v[0][1] = y; v.v[0][2] = w; v.v[0][3] = h; emit(c, OP_VIEWPORTS, &v, sizeof v); }
static void scissor(chain *c, int x, int y, int w, int h) { p_scissor sc = {x, y, w, h}; emit(c, OP_SCISSOR, &sc, sizeof sc); }
static void set_rt(chain *c, const tex_t *a) { p_set_rt r = {.n = 1}; r.color[0] = a; emit(c, OP_SET_RT, &r, sizeof r); viewport(c, 0, 0, 8, 8); scissor(c, 0, 0, 8, 8); }
static void clear_color(chain *c) { p_clear_color k = {.index = 0, .mask = 15, .rgba = {0.1f, 0.1f, 0.1f, 1}}; emit(c, OP_CLEAR_COLOR, &k, sizeof k); }
static void draw_cmd(chain *c) { p_draw d = {NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3}; emit(c, OP_DRAW, &d, sizeof d); }
static prog_t g_p; static NvProg *g_text_keep;
static void setup(void) {
    NSError *e = nil;
    id<MTLLibrary> l = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint n [[vertex_id]]) { float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; return float4(p[n], 0, 1); }\n"
        "fragment float4 f() { return float4(0.5, 0.25, 0.125, 1); }\n" options:nil error:&e];
    if (!l) { printf("%s\n", e.localizedDescription.UTF8String); abort(); }
    NvProg *p = [NvProg new]; p->sh[0] = [NvShader new]; p->sh[0]->fn = [l newFunctionWithName:@"v"];
    p->sh[1] = [NvShader new]; p->sh[1]->stage = 1; p->sh[1]->fn = [l newFunctionWithName:@"f"];
    g_p.serial = 9900; serial_put(g_p.serial, p); g_text_keep = p;
}
// Runs the chain (one submission); out: passes with draws, parts, pixels outside them, parts with a clear on load, their pixels outside
static void run(chain *c, uint64_t out[5]) {
    uint64_t a[13], b[13]; mtl_counts(a);
    emit(c, OP_END, NULL, 0); state_reset(); memset(&R, 0, sizeof R);
    mtl_sub_begin(); uint64_t hh = (uint64_t)c->p; mtl_sub_index(&hh, 1); mtl_exec(c->p);
    if (!mtl_wait(mtl_sub_commit(), 5000000000ull) || mtl_last_commit_error()) { printf("GPU did not complete\n"); abort(); }
    mtl_counts(b); out[0] = b[7] - a[7]; out[1] = b[8] - a[8]; out[2] = b[10] - a[10]; out[3] = b[11] - a[11]; out[4] = b[12] - a[12];
}
static chain begin(tex_t *T) { chain c = chain_new(); set_rt(&c, T); p_bind_program b = {&g_p, 3}; emit(&c, OP_BIND_PROGRAM, &b, sizeof b); return c; }

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); setenv("DM_NVN_COUNTS", "1", 1); setenv("DM_NVN_TBDR", "0", 1); mtl_init(); setup();
    uint64_t o[5];
    { tex_t T = tex(); chain c = begin(&T); draw_cmd(&c); run(&c, o);
      EXPECT("whole       a pass with draws", 1, o[0]);
      EXPECT("whole       ... a full-screen draw: not a part", 0, o[1]); }
    { tex_t T = tex(); chain c = begin(&T); scissor(&c, 0, 0, 4, 8); draw_cmd(&c); run(&c, o);
      EXPECT("scissor     a scissor 4 wide: a part", 1, o[1]);
      EXPECT("scissor     ... 32 pixels outside it", 32, o[2]); }
    { tex_t T = tex(); chain c = begin(&T); viewport(&c, 0, 0, 4, 4); draw_cmd(&c); run(&c, o);
      EXPECT("viewport    a 4x4 viewport under a full scissor: a part", 1, o[1]);
      EXPECT("viewport    ... 48 pixels outside it", 48, o[2]); }
    { tex_t T = tex(); chain c = begin(&T); scissor(&c, 4, 4, 4, 4); draw_cmd(&c); run(&c, o);
      EXPECT("far corner  a 4x4 scissor at (4, 4): not a part", 0, o[1]); }
    { tex_t T = tex(); chain c = begin(&T); scissor(&c, 0, 0, 4, 4); draw_cmd(&c); scissor(&c, 0, 0, 8, 8); draw_cmd(&c); run(&c, o);
      EXPECT("two draws   4x4, then full: not a part", 0, o[1]); }
    { tex_t T = tex(); chain c = begin(&T); clear_color(&c); scissor(&c, 0, 0, 4, 4); draw_cmd(&c); run(&c, o);
      EXPECT("clear first a clear on load, then a 4x4 draw: not counted as a part", 0, o[1]);
      EXPECT("clear first ... counted apart", 1, o[3]);
      EXPECT("clear first ... 48 pixels outside it", 48, o[4]); }
    { tex_t T = tex(); chain c = begin(&T); scissor(&c, 0, 0, 4, 4); draw_cmd(&c); scissor(&c, 0, 0, 8, 8); clear_color(&c); run(&c, o);
      EXPECT("clear quad  a 4x4 draw, then a full clear in the pass: not a part", 0, o[1] + o[3]); }
    printf("== %d checks, %d failed ==\n", count, fail); return fail != 0;
} }
