// Waiting for upload batches (up_wait_zero / up_notify): a waiter returns within 0.1 ms on average of the counter reaching zero and the completion
// handler's notify (30 rounds); the usleep(1000) polling it replaces returned up to a millisecond late. A waiter on a counter that is already zero
// returns at once.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int n, fail;
#define CHECK(c, ...) do { n++; if (c) printf("  ✓ "); else { fail++; printf("  ✗ "); } printf(__VA_ARGS__); printf("\n"); } while (0)
static _Atomic int g_ctr; static _Atomic uint64_t g_cleared;
static uint64_t mono(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static void *completer(void *a) { (void)a; usleep(5000); atomic_store(&g_cleared, mono()); atomic_store(&g_ctr, 0); up_notify(); return NULL; }
int main(void) { @autoreleasepool {
    double sum = 0, worst = 0; const int R = 30;
    for (int i = 0; i < R; i++) {
        atomic_store(&g_ctr, 1); pthread_t t; pthread_create(&t, NULL, completer, NULL);
        up_wait_zero(&g_ctr); double d = (double)(mono() - atomic_load(&g_cleared)); pthread_join(t, NULL);
        sum += d; if (d > worst) worst = d;
    }
    CHECK(sum / R < 100000, "a waiter returns %.3f ms on average after the completion (under 0.1 ms; worst %.3f ms)", sum / R / 1e6, worst / 1e6);
    uint64_t t0 = mono(); atomic_store(&g_ctr, 0); up_wait_zero(&g_ctr);
    CHECK(mono() - t0 < 1000000, "a counter already at zero: returns at once (%.3f ms)", (mono() - t0) / 1e6);
    printf("t_upwait: %d checks, %d failed\n", n, fail); return fail != 0;
} }
