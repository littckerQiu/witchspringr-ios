// Primitive restart (hle_nvn.c SetPrimitiveRestart, nvn_mtl.m draw): NVN restarts where an index equals the restart index exactly, and an 8-bit
// index never matches a restart index outside 0..255 (SDK); Metal restarts strips at the all-ones index only. A triangle strip 0,1,2,R,3,4,5:
// vertices 0-5 lie in the lower left corner, vertex R (7, 255) in the upper right one, so the upper right pixel is drawn only if R is a vertex.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, want, got) do { long long w=(want), g=(got); count++; printf("%-84s expected %-4lld → got %-4lld %s\n", name, w, g, w==g?"✓":"✗"); fail += w != g; } while (0)
typedef struct { uint8_t *p; size_t n; } chain;
static chain chain_new(void) { chain c={0}; if (posix_memalign((void **)&c.p,getpagesize(),65536)) abort(); memset(c.p,0,65536); mtl_pool_add(c.p,65536); return c; }
static void emit(chain *c, unsigned op, const void *a, size_t n) { size_t z=(8+n+7)&~7ull; op_hdr h={op,(uint32_t)z}; memcpy(c->p+c->n,&h,8); if(n) memcpy(c->p+c->n+8,a,n); c->n+=z; }
static tex_t tex(unsigned w) { static uint64_t s=9700; tex_t t={.serial=s++}; t.d.width=t.d.height=w; t.d.depth=t.d.samples=t.d.levels=1; t.d.target=NVN_TEXTURE_TARGET_2D; t.d.format=NVN_FORMAT_RGBA8; return t; }
static void set_rt(chain *c, const tex_t *a) { p_set_rt r={.n=1}; r.color[0]=a; emit(c,OP_SET_RT,&r,sizeof r); p_viewports v={.n=1}; v.v[0][2]=v.v[0][3]=8; emit(c,OP_VIEWPORTS,&v,sizeof v); p_scissor sc={0,0,8,8}; emit(c,OP_SCISSOR,&sc,sizeof sc);
    p_clear_color x={.index=0,.mask=15,.rgba={0,0,0,0}}; emit(c,OP_CLEAR_COLOR,&x,sizeof x);
    ds_st d={0,0,NVN_DEPTH_FUNC_ALWAYS,0,NVN_STENCIL_FUNC_ALWAYS,NVN_STENCIL_FUNC_ALWAYS,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP}; p_bind_state xs={.kind=5}; memcpy(xs.bytes,&d,sizeof d); emit(c,OP_BIND_STATE,&xs,sizeof xs); }
static uint8_t *g_mem; static prog_t g_pg;
static uint32_t corner(int itype, const void *ix, int n, int set, int en, uint32_t ridx) {   // the upper right pixel after drawing the strip
    tex_t t = tex(8); chain c = chain_new(); set_rt(&c, &t);
    p_bind_program bp = {&g_pg, 3}; emit(&c, OP_BIND_PROGRAM, &bp, sizeof bp);
    if (set) { p_prim_restart r = {en, ridx}; emit(&c, OP_PRIM_RESTART, &r, sizeof r); }
    memcpy(g_mem, ix, (size_t)n * (itype == 0 ? 1 : itype == 1 ? 2 : 4));
    p_draw_idx di = {NVN_DRAW_PRIMITIVE_TRIANGLE_STRIP, itype, n, 0, 0, 1, (uint64_t)(uintptr_t)g_mem}; emit(&c, OP_DRAW_IDX, &di, sizeof di);
    emit(&c, OP_END, NULL, 0);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); uint64_t hh = (uint64_t)c.p; mtl_sub_index(&hh, 1); mtl_exec(c.p);
    id<MTLBuffer> b = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; res_add(b);
    [blit() copyFromTexture:tex_mtl(&t) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];
    mtl_wait(mtl_sub_commit(), 5000000000ull); uint32_t v; memcpy(&v, (uint8_t *)b.contents + 7 * 4, 4); return v;
}
static uint32_t corner_after_update(const uint8_t *before, const uint8_t *after, int n) {   // 8-bit indices rewritten by an inline update earlier in the submission
    tex_t t = tex(8); chain c = chain_new(); set_rt(&c, &t);
    p_bind_program bp = {&g_pg, 3}; emit(&c, OP_BIND_PROGRAM, &bp, sizeof bp);
    memcpy(g_mem, before, n);
    uint8_t up[16 + 8] = {0}; uint64_t dst = (uint64_t)(uintptr_t)g_mem, len = 8; memcpy(up, &dst, 8); memcpy(up + 8, &len, 8); memcpy(up + 16, after, n); emit(&c, OP_UPDATE_UB, up, sizeof up);
    p_draw_idx di = {NVN_DRAW_PRIMITIVE_TRIANGLE_STRIP, 0, n, 0, 0, 1, dst}; emit(&c, OP_DRAW_IDX, &di, sizeof di);
    emit(&c, OP_END, NULL, 0);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); uint64_t hh = (uint64_t)c.p; mtl_sub_index(&hh, 1); mtl_exec(c.p);
    id<MTLBuffer> b = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; res_add(b);
    [blit() copyFromTexture:tex_mtl(&t) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];
    mtl_wait(mtl_sub_commit(), 5000000000ull); uint32_t v; memcpy(&v, (uint8_t *)b.contents + 7 * 4, 4); return v;
}
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); mtl_init();
    if (posix_memalign((void **)&g_mem, getpagesize(), 65536)) abort(); memset(g_mem, 0, 65536); mtl_pool_add(g_mem, 65536);
    NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint id [[vertex_id]]) { float2 p[6] = {float2(-1,-1), float2(-.2,-1), float2(-1,-.2), float2(-.9,-1), float2(-.5,-1), float2(-.9,-.5)}; return float4(id < 6 ? p[id] : float2(1, 1), 0, 1); }\n"
        "fragment float4 red() { return float4(1, 0, 0, 1); }\n" options:nil error:&e];
    if (!l) { printf("%s\n", e.localizedDescription.UTF8String); return 1; }
    g_pg.serial = 8800; NvProg *p = [NvProg new]; p->sh[0] = [NvShader new]; p->sh[0]->fn = [l newFunctionWithName:@"v"]; p->sh[1] = [NvShader new]; p->sh[1]->stage = 1; p->sh[1]->fn = [l newFunctionWithName:@"red"]; serial_put(g_pg.serial, p);
    const uint32_t RED = 0xff0000ff, NONE = 0;
    uint16_t s7[7] = {0, 1, 2, 7, 3, 4, 5}; uint32_t w7[7] = {0, 1, 2, 7, 3, 4, 5}; uint8_t b255[7] = {0, 1, 2, 255, 3, 4, 5};
    uint16_t sff[7] = {0, 1, 2, 0xffff, 3, 4, 5};
    EXPECT("16-bit, restart never set: 7 is a vertex (as before)", RED, corner(1, s7, 7, 0, 0, 0));
    EXPECT("16-bit, restart at 7: the strip restarts there (indices rewritten)", NONE, corner(1, s7, 7, 1, 1, 7));
    EXPECT("32-bit, restart at 7: the strip restarts there", NONE, corner(2, w7, 7, 1, 1, 7));
    EXPECT("16-bit, restart off: 7 is a vertex", RED, corner(1, s7, 7, 1, 0, 7));
    EXPECT("16-bit, restart at 0xffff: restarts at 0xffff (Metal's own)", NONE, corner(1, sff, 7, 1, 1, 0xffff));
    EXPECT("8-bit, restart at 0xffff (Tears of the Kingdom's): 255 is a vertex (SDK: no match outside 0..255)", RED, corner(0, b255, 7, 1, 1, 0xffff));
    EXPECT("8-bit, restart at 0xff: restarts at 255", NONE, corner(0, b255, 7, 1, 1, 0xff));
    // 8-bit indices an inline update earlier in the submission rewrote (wide_u8_gpu): the draw uses the new ones (0,1,2,7,...: vertex 7 reaches the corner)
    uint8_t old8[8] = {0, 1, 2, 0, 0, 0, 0, 0}, new8[8] = {0, 1, 2, 7, 3, 4, 5, 5};
    EXPECT("8-bit indices rewritten by an inline update earlier in the submission: the new ones are drawn", RED, corner_after_update(old8, new8, 7));
    printf("== %d checks, %d failed ==\n", count, fail); return fail != 0;
} }
