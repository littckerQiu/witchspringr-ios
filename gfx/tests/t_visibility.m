// Occlusion counts (NVN_COUNTER_TYPE_SAMPLES_PASSED) through real NVN recording and the production Metal replay, on the GPU: a full-screen triangle
// on an 8x8 target passes 64 samples, with a scissor of 8xN 8N. Reports within a submission (passes, draws in one pass, a reset in a pass), a
// count spanning submissions without a reset (64, then 32 → 96; then 8 → 104; an empty scissor keeps 104; a reset clears what was kept), four
// submissions held in flight (every ring buffer in use, each report its own sum), then the ring reused four times, every report still the sum
// since the reset; a submission with more counting passes than a ring buffer has slots, and its overflow buffer retired at the next one.
// After lordran-native's t_visibility (3ef6915, MIT), written for this replay. Negative control: -DDM_TEST_VIS_NO_FOLD (the slots of a reused
// buffer stay listed) fails the counts across submissions.
#include "../nvn/nvn_mtl.m"
#include "../nvn/hle_nvn.c"
const dm_game_profile dm_game = { .id = "test", .nvn_api_major = 55, .nvn_api_minor = 15, .nvn_c2 = {0x168, 128, 0x568, 128, 0x120, 8}, .nvn_depth_mode = 1 };
uint64_t g_t0_ns;
void dm_touch_screen(int w, int h) { (void)w; (void)h; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int cases, failed;
#define EXPECT(n, w, v) do { uint64_t a = (w), b = (v); cases++; printf("%-70s expected %-8llu → got %-8llu %s\n", n, (unsigned long long)a, (unsigned long long)b, a == b ? "✓" : "✗"); failed += a != b; } while (0)

static NVNcommandBuffer cmd;
static prog_t prog = {.serial = 95000};
static tex_t target = {.serial = 95001, .d = {.target = NVN_TEXTURE_TARGET_2D, .width = 8, .height = 8, .depth = 1, .levels = 1, .samples = 1, .format = NVN_FORMAT_RGBA8}};
static NVNcounterData rep[32];
static void reset(void) { h_nvnCommandBufferResetCounter(&cmd, NVN_COUNTER_TYPE_SAMPLES_PASSED); }
static void report(int i) { h_nvnCommandBufferReportCounter(&cmd, NVN_COUNTER_TYPE_SAMPLES_PASSED, (NVNbufferAddress)(uintptr_t)&rep[i]); }
static void scissor(int w, int h) { h_nvnCommandBufferSetScissor(&cmd, 0, 0, w, h); }
static void pass(void) {   // a new render pass on the target
    const NVNtexture *t[] = {(const NVNtexture *)&target};
    h_nvnCommandBufferSetRenderTargets(&cmd, 1, t, NULL, NULL, NULL);
    scissor(8, 8);
    float black[] = {0, 0, 0, 1}; h_nvnCommandBufferClearColor(&cmd, 0, black, NVN_CLEAR_COLOR_MASK_RGBA);
}
static void triangle(void) { h_nvnCommandBufferDrawArrays(&cmd, NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3); }
static void begin(void) { h_nvnCommandBufferBeginRecording(&cmd); h_nvnCommandBufferBindProgram(&cmd, (const NVNprogram *)&prog, 3); }
static uint64_t submit_async(void) { NVNcommandHandle h = h_nvnCommandBufferEndRecording(&cmd); mtl_sub_begin(); mtl_exec((const uint8_t *)h); return mtl_sub_commit(); }
static void complete(uint64_t f) { int done = mtl_wait(f, 5000000000ull); if (!done) { printf("GPU did not complete\n"); abort(); } if (mtl_last_commit_error()) { printf("GPU error\n"); abort(); } }
static void submit(void) { complete(submit_async()); }

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); setenv("DM_NVN_TBDR", "0", 1); mtl_init();
    NSError *e = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint n [[vertex_id]]) { float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; return float4(p[n], .5, 1); }\n"
        "fragment float4 f() { return float4(1); }\n" options:nil error:&e];
    if (!lib) { printf("%s\n", e.localizedDescription.UTF8String); return 2; }
    NvProg *p = [NvProg new]; p->sh[0] = [NvShader new]; p->sh[0]->fn = [lib newFunctionWithName:@"v"];
    p->sh[1] = [NvShader new]; p->sh[1]->fn = [lib newFunctionWithName:@"f"]; p->sh[1]->stage = 1; serial_put(prog.serial, p);
    enum { MEM = 8 << 20 };
    void *mem; if (posix_memalign(&mem, 16384, MEM)) return 2;
    pool_t pool = {.mem = mem, .size = MEM}; mtl_pool_add(mem, MEM);
    h_nvnCommandBufferInitialize(&cmd, NULL); h_nvnCommandBufferAddCommandMemory(&cmd, (const NVNmemoryPool *)&pool, 0, MEM);

    begin(); reset(); pass(); triangle(); report(0); pass(); triangle(); report(1); pass(); triangle(); report(2); submit();
    EXPECT("a report is the count at its place, later passes not in it", 64, rep[0].counter);
    EXPECT("two passes", 128, rep[1].counter);
    EXPECT("three passes", 192, rep[2].counter);
    begin(); reset(); pass(); triangle(); report(3); triangle(); report(4); reset(); report(5); triangle(); report(6); submit();
    EXPECT("draws of one pass: the first report", 64, rep[3].counter);
    EXPECT("draws of one pass: the second report counts both", 128, rep[4].counter);
    EXPECT("a reset with no draw after it reports 0", 0, rep[5].counter);
    EXPECT("a reset inside a pass starts a new count", 64, rep[6].counter);

    uint64_t f0 = g_vis_folded;
    begin(); reset(); pass(); triangle(); report(7); submit();
    begin(); pass(); scissor(8, 4); triangle(); report(8); submit();
    EXPECT("count across submissions: before the boundary", 64, rep[7].counter);
    EXPECT("count across submissions: 64 then 32 (the reused buffer kept)", 96, rep[8].counter);
    begin(); pass(); scissor(2, 4); triangle(); report(9); submit();
    EXPECT("a third submission adds 8", 104, rep[9].counter);
    begin(); pass(); scissor(0, 0); triangle(); report(10); submit();
    EXPECT("a draw passing nothing keeps the earlier submissions' samples", 104, rep[10].counter);
    EXPECT("slots of reused buffers were kept as samples", 1, g_vis_folded > f0);
    begin(); reset(); report(11); submit();
    EXPECT("a reset clears the kept samples too", 0, rep[11].counter);
    begin(); reset(); pass(); triangle(); report(12); submit();
    EXPECT("a reused buffer brings no old count", 64, rep[12].counter);

    // Four submissions held behind an event: every ring buffer in use at once, nothing reported before the GPU runs them
    id<MTLSharedEvent> gate = [g_dev newSharedEvent];
#if DM_NVN_M3
    { id<MTLCommandBuffer> w = [g_q commandBuffer]; [w encodeWaitForEvent:gate value:1]; [w commit]; }
#else
    [g_q4 waitForEvent:gate value:1];
#endif
    uint64_t f = 0, want = 0;
    for (int i = 0; i < 4; i++) { rep[13 + i].counter = UINT64_MAX; begin(); if (!i) reset(); pass(); scissor(8, i + 1); triangle(); report(13 + i); f = submit_async(); }
    EXPECT("all four ring buffers in use", 4, g_vis_ring_n);
    EXPECT("no report written before its submission runs", UINT64_MAX, rep[13].counter);
    gate.signaledValue = 1; complete(f);
    int bad = 0; for (int i = 0; i < 4; i++) { want += 8 * (i + 1); bad += rep[13 + i].counter != want; }
    EXPECT("each held submission reports its own sum (8, 24, 48, 80)", 0, bad);
    bad = 0; for (int i = 4; i < 8; i++) { begin(); pass(); scissor(8, i + 1); triangle(); report(13 + i); submit(); want += 8 * (i + 1); bad += rep[13 + i].counter != want; }
    EXPECT("the ring reused four more times: every report the sum since the reset", 0, bad);
    EXPECT("... the last one", want, rep[20].counter);

    // More counting passes than a ring buffer has slots: the last ones count in an overflow buffer, retired when the next submission begins
    begin(); reset(); for (int i = 0; i < VIS_SLOTS + 2; i++) { pass(); triangle(); } report(21); submit();
    EXPECT("8,194 counting passes in one submission", (uint64_t)(VIS_SLOTS + 2) * 64, rep[21].counter);
    id<MTLBuffer> ov = g_vis;
    EXPECT("its last passes counted in an overflow buffer", 1, ov && !vis_in_ring(ov));
    begin(); pass(); triangle(); report(22); submit();
    EXPECT("... the count continues in the next submission", (uint64_t)(VIS_SLOTS + 3) * 64, rep[22].counter);
    begin(); pass(); submit();   // the retirement waits for the submission that used it
    pthread_mutex_lock(&g_res_mu); int resident = [g_res_objects containsObject:ov]; pthread_mutex_unlock(&g_res_mu);
    EXPECT("the overflow buffer left the residency set", 0, resident);

    h_nvnCommandBufferFinalize(&cmd); mtl_pool_del(mem); free(mem);
    printf("== %d checks, %d failed ==\n", cases, failed); return failed != 0;
} }
