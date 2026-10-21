// The lock / condition variable trace in the thread dump (hle_thread.c kt / kt_dump): a guest thread waits on a condition variable (untimed), the
// main thread signals it, the guest unlocks; the dump lists the wait, the wake, the signal and the unlock with their addresses, and leaves out a
// timed wait on another key. DM_DEBUG_CV_LATE_WAIT=20000 (set here) starts every condition variable wait 20 ms late.
#include "../dm.h"
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>
int svc_thread(int num, uint64_t *regs);
uint32_t svc_thread_main_init(void);
void svc_thread_dump(void);
void (*dm_test_cv_after_release)(void);   // DM_TEST_HOOKS (t_condvar uses it)
static int n, fail;
#define CHECK(c, ...) do { n++; if (c) printf("  ✓ "); else { fail++; printf("  ✗ "); } printf(__VA_ARGS__); printf("\n"); } while (0)
static _Alignas(8) uint32_t g_lock, g_key, g_key2;
static _Atomic int g_blocked, g_done; static double g_timed_ms;
static double ms(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }
static void *guest(void *a) {
    (void)a; uint32_t me = svc_thread_main_init();
    g_lock = me;   // this thread holds the lock
    atomic_store(&g_blocked, 1);
    uint64_t w[32] = {(uint64_t)&g_lock, (uint64_t)&g_key, me, (uint64_t)-1}; svc_thread(0x1C, w);   // untimed wait: woken by the main thread's signal
    uint64_t u[32] = {(uint64_t)&g_lock}; svc_thread(0x1B, u);                                         // unlock
    g_lock = me; double t0 = ms();
    uint64_t tw[32] = {(uint64_t)&g_lock, (uint64_t)&g_key2, me, 1000000}; svc_thread(0x1C, tw);         // timed wait (1 ms) on another key: not traced
    g_timed_ms = ms() - t0;
    atomic_store(&g_done, 1); return NULL;
}
int main(void) {
    setenv("DM_DEBUG_CV_LATE_WAIT", "20000", 1);
    pthread_t t; pthread_create(&t, NULL, guest, NULL);
    while (!atomic_load(&g_blocked)) usleep(1000);
    usleep(80000);   // past the 20 ms late start and into the wait
    uint64_t s[32] = {(uint64_t)&g_key, 1}; svc_thread(0x1D, s);
    pthread_join(t, NULL);
    const char *td = getenv("TMPDIR"); char pth[1024]; snprintf(pth, sizeof pth, "%s/t_ktrace.XXXXXX", td ? td : "/private/tmp");
    int fd = mkstemp(pth), save = dup(2); fflush(stderr); dup2(fd, 2); svc_thread_dump(); fflush(stderr); dup2(save, 2); close(save);
    static char out[1 << 16]; lseek(fd, 0, SEEK_SET); ssize_t k = read(fd, out, sizeof out - 1); out[k > 0 ? k : 0] = 0; close(fd); unlink(pth);
    char kw[64], kl[64], k2[64]; snprintf(kw, sizeof kw, "%#llx", (unsigned long long)(uintptr_t)&g_key); snprintf(kl, sizeof kl, "%#llx", (unsigned long long)(uintptr_t)&g_lock);
    snprintf(k2, sizeof k2, "%#llx", (unsigned long long)(uintptr_t)&g_key2);
    const char *w = strstr(out, "cv wait"), *wk = strstr(out, "cv woke"), *sg = strstr(out, "cv signal"), *ul = strstr(out, "unlock");
    CHECK(strstr(out, "lock / condition variable calls") != NULL, "the dump has the trace");
    CHECK(w && wk && sg && ul && w < sg && sg < wk && wk < ul, "wait, signal, wake, unlock in that order");
    char wl[256] = ""; if (w) { size_t e = strcspn(w, "\n"); snprintf(wl, sizeof wl, "%.*s", (int)(e < 255 ? e : 255), w); }
    CHECK(strstr(wl, kw) && strstr(wl, kl), "the wait line has the condition key and the lock's address (%s)", wl);
    CHECK(strstr(out, k2) == NULL, "the timed wait on another key is left out");
    CHECK(g_timed_ms >= 20, "DM_DEBUG_CV_LATE_WAIT=20000: the 1 ms timed wait took %.1f ms (at least 20)", g_timed_ms);
    printf("t_ktrace: %d checks, %d failed\n", n, fail); return fail != 0;
}
