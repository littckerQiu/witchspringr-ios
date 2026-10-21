// A frame's GPU time (mtl_gpu_ms) is the union of its command buffers' spans, not their sum: Apple GPUs overlap buffers. Spans [0,10] [5,12]
// [20,25] ms give 17 (the old sum gave 22); disjoint, nested and a frame still running; more spans than the list holds: overlapping ones still
// give the exact union, disjoint ones stay between the union and the envelope. mtl_gpu_sum_ms keeps the old sum.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int n, fail;
#define EXPECT(name, want, got) do { long long w_ = (want), g_ = (got); n++; printf("%-84s expected %-6lld → got %-6lld %s\n", name, w_, g_, w_ == g_ ? "✓" : "✗"); fail += w_ != g_; } while (0)
static long long us(double ms) { return llround(ms * 1000); }   // compare in microseconds
static void frame(uint64_t f, const double (*iv)[2], int k) {   // k command buffers of frame f, spans in ms from a 100 s base
    for (int i = 0; i < k; i++) gpu_tag_begin(f);
    for (int i = 0; i < k; i++) gpu_tag_done(f, 100 + iv[i][0] / 1e3, 100 + iv[i][1] / 1e3);
}
int main(void) { @autoreleasepool {
    static const double a[3][2] = {{0, 10}, {5, 12}, {20, 25}};
    frame(1, a, 3);
    EXPECT("[0,10] [5,12] [20,25]: the union, 17 ms", us(17), us(mtl_gpu_ms(1)));
    EXPECT("... the plain sum is still there for comparison, 22 ms", us(22), us(mtl_gpu_sum_ms(1)));
    static const double b[2][2] = {{0, 1}, {2, 3}}; frame(2, b, 2);
    EXPECT("disjoint [0,1] [2,3]: 2 ms", us(2), us(mtl_gpu_ms(2)));
    static const double c[2][2] = {{0, 10}, {2, 3}}; frame(3, c, 2);
    EXPECT("nested [0,10] [2,3]: 10 ms", us(10), us(mtl_gpu_ms(3)));
    gpu_tag_begin(4); gpu_tag_begin(4); gpu_tag_done(4, 100, 100.001);
    EXPECT("one of two buffers still running: not known yet (-1)", -1, (long long)mtl_gpu_ms(4));
    static double d[300][2]; for (int i = 0; i < 300; i++) { d[i][0] = i * 0.01; d[i][1] = 10 - i * 0.01; } frame(5, d, 300);
    EXPECT("300 nested spans (more than the list holds): the exact union, 10 ms", us(10), us(mtl_gpu_ms(5)));
    static double e[300][2]; for (int i = 0; i < 300; i++) { e[i][0] = i * 0.2; e[i][1] = i * 0.2 + 0.1; } frame(6, e, 300);
    double u = mtl_gpu_ms(6);
    EXPECT("300 disjoint 0.1 ms spans: at least their union (30 ms)", 1, u >= 30 - 1e-6);
    EXPECT("... and at most their envelope (59.9 ms)", 1, u <= 59.9 + 1e-6);
    frame(1 + GIVR, a, 3);
    EXPECT("a frame whose span list was taken over by a later frame: not known (-1)", -1, (long long)mtl_gpu_ms(1));
    printf("t_gputime: %d checks, %d failed\n", n, fail); return fail != 0;
} }
