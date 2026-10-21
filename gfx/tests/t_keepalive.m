// GPU keep-alive (nvn_mtl.m keepalive_start): spin kernels run while the game submits and its own command buffers are not on the GPU, none while
// one is in flight, and they stop 100 ms after the last submission. Forced on with DM_NVN_KEEPALIVE=1 (the tests have no window).
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, want, got) do { long long w=(want), g=(got); count++; printf("%-70s expected %-4lld → got %-4lld %s\n", name, w, g, w==g?"✓":"✗"); fail += w != g; } while (0)
static void submit(void) { mtl_sub_begin(); mtl_wait(mtl_sub_commit(), 5000000000ull); }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); setenv("DM_NVN_KEEPALIVE", "1", 1); mtl_init();
    submit(); usleep(60000);
    uint64_t a = atomic_load(&g_ka_n);
    EXPECT("after a submission: spin kernels ran", 1, a > 0);
    atomic_store(&g_inflight, 1); atomic_store(&g_last_sub_ns, clock_gettime_nsec_np(CLOCK_UPTIME_RAW)); usleep(20000);   // a game command buffer in flight
    uint64_t b0 = atomic_load(&g_ka_n); usleep(40000); atomic_store(&g_last_sub_ns, clock_gettime_nsec_np(CLOCK_UPTIME_RAW)); usleep(40000);
    EXPECT("while a game command buffer is in flight: none", 0, (long long)(atomic_load(&g_ka_n) - b0));
    atomic_store(&g_inflight, 0); dispatch_semaphore_signal(g_ka_idle);
    usleep(300000); uint64_t c0 = atomic_load(&g_ka_n); usleep(200000);
    EXPECT("more than 100 ms after the last submission: none", 0, (long long)(atomic_load(&g_ka_n) - c0));
    printf("== %d checks, %d failed ==\n", count, fail); return fail != 0;
} }
