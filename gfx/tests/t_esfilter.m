// Render state filter (nvn_mtl.m enc_r_* with g_es): an unchanged state is not set again on the same encoder, a changed one is, and a new encoder
// gets every state again (a cache kept across encoders would leave the second pass at Metal's default scissor: the whole target drawn).
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, want, got) do { long long w=(want), g=(got); count++; printf("%-74s expected %-6lld → got %-6lld %s\n", name, w, g, w==g?"✓":"✗"); fail += w != g; } while (0)
typedef struct { uint8_t *p; size_t n; } chain;
static void emit(chain *c, unsigned op, const void *a, size_t n) { size_t z=(8+n+7)&~7ull; op_hdr h={op,(uint32_t)z}; memcpy(c->p+c->n,&h,8); if(n) memcpy(c->p+c->n+8,a,n); c->n+=z; }
static int red_count(const tex_t *t, id<MTLBuffer> rb) { (void)t; int n = 0; for (int i = 0; i < 64; i++) n += ((uint8_t *)rb.contents)[i * 4] == 255; return n; }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); mtl_init();
    NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal; vertex float4 v(uint n[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[n],0,1);}\n"
        "fragment float4 red() { return float4(1, 0, 0, 1); }\n" options:nil error:&e];
    static prog_t pg = {.serial = 8950}; NvProg *p = [NvProg new]; p->sh[0] = [NvShader new]; p->sh[0]->fn = [l newFunctionWithName:@"v"]; p->sh[1] = [NvShader new]; p->sh[1]->stage = 1; p->sh[1]->fn = [l newFunctionWithName:@"red"]; serial_put(pg.serial, p);
    uint8_t *cm; if (posix_memalign((void **)&cm, getpagesize(), 1 << 20)) abort(); memset(cm, 0, 1 << 20); mtl_pool_add(cm, 1 << 20); chain c = {cm, 0};
    tex_t a = {.serial = 9850}, b = {.serial = 9851};
    for (tex_t *t = &a; t; t = t == &a ? &b : NULL) { t->d.width = t->d.height = 8; t->d.depth = t->d.samples = t->d.levels = 1; t->d.target = NVN_TEXTURE_TARGET_2D; t->d.format = NVN_FORMAT_RGBA8; }
    p_bind_program bp = {&pg, 3}; emit(&c, OP_BIND_PROGRAM, &bp, sizeof bp);
    ds_st d = {0, 0, NVN_DEPTH_FUNC_ALWAYS, 0, NVN_STENCIL_FUNC_ALWAYS, NVN_STENCIL_FUNC_ALWAYS, 1, 1, 1, 1, 1, 1}; p_bind_state x = {.kind = 5}; memcpy(x.bytes, &d, sizeof d); emit(&c, OP_BIND_STATE, &x, sizeof x);
    for (int k = 0; k < 2; k++) {   // two passes, each: clear, left-half scissor, three draws (two unchanged), then the top-left quarter
        p_set_rt rt = {.n = 1}; rt.color[0] = k ? &b : &a; emit(&c, OP_SET_RT, &rt, sizeof rt);
        p_viewports v = {.n = 1}; v.v[0][2] = v.v[0][3] = 8; emit(&c, OP_VIEWPORTS, &v, sizeof v);
        p_scissor full = {0, 0, 8, 8}; emit(&c, OP_SCISSOR, &full, sizeof full);
        p_clear_color cc = {.index = 0, .mask = 15, .rgba = {0, 0, 0, 0}}; emit(&c, OP_CLEAR_COLOR, &cc, sizeof cc);
        p_scissor half = {0, 0, 4, 8}; emit(&c, OP_SCISSOR, &half, sizeof half);
        p_draw dr = {NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3}; for (int j = 0; j < 3; j++) emit(&c, OP_DRAW, &dr, sizeof dr);
        p_set_rt none = {.n = 0}; emit(&c, OP_SET_RT, &none, sizeof none);
    }
    emit(&c, OP_END, NULL, 0);
    setenv("DM_NVN_TBDR", "0", 1);   // two separate passes
    uint64_t s0, k0; mtl_es_stats(&s0, &k0);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); uint64_t hh = (uint64_t)c.p; mtl_sub_index(&hh, 1); mtl_exec(c.p);
    id<MTLBuffer> ra = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared], rb = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; res_add(ra); res_add(rb);
    [blit() copyFromTexture:tex_mtl(&a) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:ra destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];
    [blit() copyFromTexture:tex_mtl(&b) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];
    mtl_wait(mtl_sub_commit(), 5000000000ull);
    uint64_t s1, k1; mtl_es_stats(&s1, &k1);
    EXPECT("first pass: the left half drawn (32 pixels)", 32, red_count(&a, ra));
    EXPECT("second pass, a new encoder: its scissor set again (32 pixels)", 32, red_count(&b, rb));
    EXPECT("unchanged states on the same encoder were skipped", 1, k1 > k0);
    printf("== %d checks, %d failed ==\n", count, fail); return fail != 0;
} }
