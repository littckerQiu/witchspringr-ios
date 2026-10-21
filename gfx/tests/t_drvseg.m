// NVN driver segment c0 for compute and vertex shaders (nvn_refl.m: a declared driver-segment binding counts as read; nvn_mtl.m drv_fill: the
// compute dispatch size at 0x200, the compute uniform buffer table at 0x210, the storage buffer tables, the largest point size at 0x610).
// End to end: a compute kernel reflected from json as dmsh_build.py writes it (drvcb binding, drv_reads empty, as the fragment-only scan left
// every compute shader) copies c0 words into a storage buffer through a real dispatch. Before the fix the segment was all zeros.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, want, got) do { unsigned long long w=(unsigned long long)(want), g=(unsigned long long)(got); count++; printf("%-70s expected %-14llx → got %-14llx %s\n", name, w, g, w==g?"✓":"✗"); fail += w != g; } while (0)
typedef struct { uint8_t *p; size_t n; } chain;
static void emit(chain *c, unsigned op, const void *a, size_t n) { size_t z=(8+n+7)&~7ull; op_hdr h={op,(uint32_t)z}; memcpy(c->p+c->n,&h,8); if(n) memcpy(c->p+c->n+8,a,n); c->n+=z; }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); mtl_init();
    uint8_t *mem; if (posix_memalign((void **)&mem, getpagesize(), 65536)) abort(); memset(mem, 0, 65536); mtl_pool_add(mem, 65536);
    uint64_t out = (uint64_t)(uintptr_t)mem, ubo = out + 0x1000;
    // 1. Reflection: the json of a compute shader that reads c0 (drv_reads empty, as the fragment-only scan wrote it)
    NSDictionary *j = @{@"route": @"B", @"stage": @"cs", @"c2": @{@"tex": @[@(mtl_c2_tex_base()), @128], @"samp": @[@(mtl_c2_samp_base()), @128]},
        @"bindings": @[@{@"msl_name": @"cp_c0", @"kind": @"drvcb", @"bank": @0, @"arg_id": @0}, @{@"msl_name": @"cp_s0", @"kind": @"sbuf", @"arg_id": @1, @"reg": @0, @"rw": @YES}],
        @"drv_reads": @{}, @"threadgroup_size": @[@1, @1, @1]};
    nvn_refl rf; char err[256] = "";
    EXPECT("the json parses", 0, nvn_refl_from_json(j, &rf, err, sizeof err));
    EXPECT("a declared c0 binding counts as read although drv_reads is empty", 1, rf.drv_read[0]);
    // 2. A real dispatch: the kernel copies c0 + 0x200 (dispatch size), + 0x210 (uniform slot 0), + 0x310 (storage slot 0) to the storage buffer
    NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct A { constant uint4 *cp_c0 [[id(0)]]; device uint4 *cp_s0 [[id(1)]]; };\n"
        "kernel void k(constant A &a [[buffer(0)]], uint3 g [[threadgroup_position_in_grid]]) { if (g.x == 0 && g.y == 0 && g.z == 0) { a.cp_s0[0] = a.cp_c0[32]; a.cp_s0[1] = a.cp_c0[33]; a.cp_s0[2] = a.cp_c0[49]; } }\n" options:nil error:&e];
    if (!l) { printf("%s\n", e.localizedDescription.UTF8String); return 1; }
    static prog_t pg = {.serial = 8700}; NvProg *p = [NvProg new]; p->sh[5] = [NvShader new]; p->sh[5]->stage = 5; p->sh[5]->fn = [l newFunctionWithName:@"k"];
    p->sh[5]->rf = rf; p->sh[5]->ae = [p->sh[5]->fn newArgumentEncoderWithBufferIndex:0]; serial_put(pg.serial, p);
    chain c = {0}; if (posix_memalign((void **)&c.p, getpagesize(), 65536)) abort(); memset(c.p, 0, 65536); mtl_pool_add(c.p, 65536);
    p_bind_program bp = {&pg, NVN_SHADER_STAGE_COMPUTE_BIT}; emit(&c, OP_BIND_PROGRAM, &bp, sizeof bp);
    p_bind_buf sb = {NVN_SHADER_STAGE_COMPUTE, 0, out, 256}; emit(&c, OP_BIND_SSBO, &sb, sizeof sb);
    p_bind_buf ub = {NVN_SHADER_STAGE_COMPUTE, 0, ubo, 512}; emit(&c, OP_BIND_UBO, &ub, sizeof ub);
    p_dispatch d = {3, 5, 7, 0}; emit(&c, OP_DISPATCH, &d, sizeof d); emit(&c, OP_END, NULL, 0);
    state_reset(); mtl_sub_begin(); uint64_t hh = (uint64_t)c.p; mtl_sub_index(&hh, 1); mtl_sub_snapshot(&hh, 1); mtl_exec(c.p);
    EXPECT("submission completed", 1, mtl_wait(mtl_sub_commit(), 5000000000ull));
    EXPECT("no error in the submission's feedback", 0, mtl_last_commit_error());
    const uint32_t *o = (const uint32_t *)mem;
    EXPECT("c0 + 0x200: workgroups x", 3, o[0]); EXPECT("c0 + 0x204: workgroups y", 5, o[1]); EXPECT("c0 + 0x208: workgroups z", 7, o[2]);
    EXPECT("c0 + 0x210: uniform slot 0 address", ubo, (uint64_t)o[4] | (uint64_t)o[5] << 32); EXPECT("c0 + 0x218: uniform slot 0 size", 512, o[6]);
    EXPECT("c0 + 0x310: storage slot 0 address", out, (uint64_t)o[8] | (uint64_t)o[9] << 32); EXPECT("c0 + 0x318: storage slot 0 size", 256, o[10]);
    // 2b. Two dispatches in a row (Metal 4: one compute encoder with a barrier between them): the second reads what the first wrote
    {
        NSDictionary *j2 = @{@"route": @"B", @"stage": @"cs", @"c2": @{@"tex": @[@(mtl_c2_tex_base()), @128], @"samp": @[@(mtl_c2_samp_base()), @128]},
            @"bindings": @[@{@"msl_name": @"cp_s0", @"kind": @"sbuf", @"arg_id": @0, @"reg": @0, @"rw": @YES}], @"drv_reads": @{}, @"threadgroup_size": @[@1, @1, @1]};
        nvn_refl r2; nvn_refl_from_json(j2, &r2, err, sizeof err);
        id<MTLLibrary> l2 = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nstruct A { device uint4 *cp_s0 [[id(0)]]; };\n"
            "kernel void w(constant A &a [[buffer(0)]]) { a.cp_s0[8] = uint4(123, 0, 0, 0); }\nkernel void r(constant A &a [[buffer(0)]]) { a.cp_s0[9] = a.cp_s0[8] + uint4(1, 0, 0, 0); }\n" options:nil error:&e];
        static prog_t pw = {.serial = 8701}, pr = {.serial = 8702};
        for (int i = 0; i < 2; i++) { NvProg *q = [NvProg new]; q->sh[5] = [NvShader new]; q->sh[5]->stage = 5; q->sh[5]->fn = [l2 newFunctionWithName:i ? @"r" : @"w"]; q->sh[5]->rf = r2;
            q->sh[5]->ae = [q->sh[5]->fn newArgumentEncoderWithBufferIndex:0]; serial_put(i ? pr.serial : pw.serial, q); }
        chain c2 = {0}; if (posix_memalign((void **)&c2.p, getpagesize(), 65536)) abort(); memset(c2.p, 0, 65536); mtl_pool_add(c2.p, 65536);
        p_bind_buf sb2 = {NVN_SHADER_STAGE_COMPUTE, 0, out, 256}; emit(&c2, OP_BIND_SSBO, &sb2, sizeof sb2);
        p_bind_program b1 = {&pw, NVN_SHADER_STAGE_COMPUTE_BIT}; emit(&c2, OP_BIND_PROGRAM, &b1, sizeof b1);
        p_dispatch d1 = {1, 1, 1, 0}; emit(&c2, OP_DISPATCH, &d1, sizeof d1);
        p_bind_program b2 = {&pr, NVN_SHADER_STAGE_COMPUTE_BIT}; emit(&c2, OP_BIND_PROGRAM, &b2, sizeof b2);
        emit(&c2, OP_DISPATCH, &d1, sizeof d1); emit(&c2, OP_END, NULL, 0);
        uint64_t sh0 = g_disp_shared;
        state_reset(); mtl_sub_begin(); uint64_t h2 = (uint64_t)c2.p; mtl_sub_index(&h2, 1); mtl_sub_snapshot(&h2, 1); mtl_exec(c2.p);
        EXPECT("two dispatches: submission completed", 1, mtl_wait(mtl_sub_commit(), 5000000000ull));
        EXPECT("the second dispatch read the first one's write (123 + 1)", 124, o[36]);
#if !DM_NVN_M3
        EXPECT("Metal 4: the second dispatch went into the open encoder", 1, g_disp_shared > sh0);
#endif
    }
    // 3. The graphics stages' words (CPU): the vertex storage table at 0x110 and the largest point size at 0x610
    uint8_t seg[0xA00]; S.ssbo[0][1] = (p_bind_buf){0, 1, 0x123456789abc0ull, 0x40};
    drv_fill(seg, 0, NVN_SHADER_STAGE_VERTEX);
    uint64_t a; uint32_t n; float ps; memcpy(&a, seg + 0x120, 8); memcpy(&n, seg + 0x128, 4); memcpy(&ps, seg + 0x610, 4);
    EXPECT("vertex c0 + 0x120: storage slot 1 address", 0x123456789abc0ull, a); EXPECT("vertex c0 + 0x128: storage slot 1 size", 0x40, n);
    EXPECT("vertex c0 + 0x610: largest point size 2047.9375 (bits)", 0x44fffe00, *(uint32_t *)&ps);
    drv_fill(seg, 0, NVN_SHADER_STAGE_COMPUTE); memcpy(&ps, seg + 0x610, 4);
    EXPECT("compute c0 + 0x610 stays 0 (inside no table there)", 0, *(uint32_t *)&ps);
    printf("== %d checks, %d failed ==\n", count, fail); return fail != 0;
} }
