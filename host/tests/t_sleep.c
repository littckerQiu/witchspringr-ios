// svc 0x0B SleepThread lasts what was asked for: the mean oversleep of 5 ms and 33.3 ms sleeps stays under 0.2 ms, or under a third of what one plain
// nanosleep oversleeps on this machine right now, and no sleep ends more than 0.05 ms early. One plain nanosleep overslept by about a quarter (1.17 /
// 4.27 ms on 5 / 33.3 ms on an M5 at the default QoS), and by twice that while the system coalesced timers harder (the display asleep, it seems):
// the step loop then still ends within 0.6 / 1.3 ms, but no longer within 0.2.
// Yield back-off: a guest thread yielding back to back for 20 ms makes far fewer than 50,000 yields, 20-500 of them short sleeps (from the 2 ms
// start on), and its loop ends within one capped sleep of the 20 ms (250 µs plus the slack a plain nanosleep shows right now, + 0.1 ms); a run of
// 1.5 ms (under the 2 ms start) and yields with another SVC between them never back off. The back-off is off by default: the test turns it on with
// DM_YIELD_BACKOFF=250 unless set; DM_YIELD_BACKOFF=0 (plain yields, the default in the games) fails the first, DM_YIELD_BACKOFF=250:200 (the old
// 200 µs start) the 1.5 ms run.
// Timing test: run it on a machine that is not saturated. A machine whose timers are coarse (GitHub's macOS runner, a virtual machine: a plain 5 ms
// nanosleep overslept by 14.8 ms, every short sleep took about 1.4 ms) cannot show the bounds: when a plain 5 ms nanosleep oversleeps by more than
// 5 ms the oversleep, sleep count and lateness bounds are printed, not checked (DM_TEST_TIMING=1 checks them anyway); never early, the yield count
// and no back-off between other SVCs are checked everywhere.
#include "../dm.h"
#include <pthread.h>
#include <pthread/qos.h>
#include <time.h>
int svc_thread(int num, uint64_t *regs);
uint32_t svc_thread_main_init(void);
void dm_yield_top(char *out, size_t n);
#include <stdlib.h>
#include <string.h>
void (*dm_test_cv_after_release)(void);   // DM_TEST_HOOKS (t_condvar uses it)
static int n, fail, coarse; static double slack5;   // a plain 5 ms nanosleep's oversleep / 5 ms
#define CHECK(c, ...) do { n++; if (c) printf("  ✓ "); else { fail++; printf("  ✗ "); } printf(__VA_ARGS__); printf("\n"); } while (0)
static uint64_t now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static void *guest(void *a) {
    (void)a; pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);   // as hle_thread.c starts guest threads (at a lower QoS macOS coalesces timers more)
    svc_thread_main_init();
    static const uint64_t want[] = {5000000, 33333333}; static const int reps[] = {40, 10};
    for (int k = 0; k < 2; k++) {
        double plain = 0; for (int i = 0; i < reps[k] / 2; i++) { uint64_t t0 = now(); struct timespec ts = {0, (long)want[k]}; nanosleep(&ts, 0); plain += (double)(now() - t0) - (double)want[k]; }
        plain /= reps[k] / 2; double lim = plain / 3 > 200000 ? plain / 3 : 200000;
        if (k == 0) { const char *e = getenv("DM_TEST_TIMING"); coarse = plain > 5e6 && !(e && !strcmp(e, "1")); slack5 = plain / 5e6; }
        double over = 0, early = 0;
        for (int i = 0; i < reps[k]; i++) {
            uint64_t r[32] = {want[k]}, t0 = now(); svc_thread(0x0B, r); double d = (double)(now() - t0) - (double)want[k];
            over += d; if (-d > early) early = -d;
        }
        over /= reps[k];
        if (coarse) printf("  - SleepThread(%.1f ms): mean oversleep %.3f ms, a plain nanosleep's %.3f: coarse timers, not checked\n", want[k] / 1e6, over / 1e6, plain / 1e6);
        else CHECK(over < lim, "SleepThread(%.1f ms): mean oversleep %.3f ms (under %.3f: 0.2 ms or a third of a plain nanosleep's %.3f)", want[k] / 1e6, over / 1e6, lim / 1e6, plain / 1e6);
        CHECK(early <= 50000, "SleepThread(%.1f ms): never more than 0.05 ms early (earliest %.3f ms)", want[k] / 1e6, early / 1e6);
    }
    // yield back-off
    char top[256]; dm_yield_top(top, sizeof top);   // reset the counts
    uint64_t t0 = now(), yields = 0; while (now() - t0 < 20000000) { uint64_t r[32] = {0}; svc_thread(0x0B, r); yields++; }
    double late = (double)(now() - t0) - 20e6;
    dm_yield_top(top, sizeof top); const char *b = strstr(top, "back-off sleeps "); long sleeps = b ? atol(b + 16) : -1;
    CHECK(yields < 50000, "20 ms of back-to-back yields: %llu yields (fewer than 50,000)", (unsigned long long)yields);
    if (coarse) printf("  - ... %ld of them short sleeps, the loop ends %.3f ms after the 20 ms: coarse timers, not checked\n", sleeps, late / 1e6);
    else { CHECK(sleeps >= 20 && sleeps <= 500, "... %ld of them short sleeps (20-500)", sleeps);
           double lim = 250000 * (1 + slack5) + 100000;   // the last sleep (at most the 250 µs cap) with this machine's timer slack right now
           CHECK(late < lim, "... the loop ends %.3f ms after the 20 ms (under %.3f: one 250 µs sleep with a plain sleep's slack, + 0.1)", late / 1e6, lim / 1e6); }
    { uint64_t q[32] = {0, 0xFFFF8000u}; svc_thread(0x0C, q); }   // another SVC: the run of yields above ends here
    t0 = now(); while (now() - t0 < 1500000) { uint64_t r[32] = {0}; svc_thread(0x0B, r); }
    dm_yield_top(top, sizeof top); b = strstr(top, "back-off sleeps "); sleeps = b ? atol(b + 16) : -1;
    CHECK(sleeps == 0, "1.5 ms of back-to-back yields (under the 2 ms start): no back-off (%ld sleeps)", sleeps);
    { uint64_t q[32] = {0, 0xFFFF8000u}; svc_thread(0x0C, q); }
    t0 = now(); while (now() - t0 < 5000000) { uint64_t r[32] = {0}; svc_thread(0x0B, r); uint64_t q[32] = {0, 0xFFFF8000u}; svc_thread(0x0C, q); }
    dm_yield_top(top, sizeof top); b = strstr(top, "back-off sleeps "); sleeps = b ? atol(b + 16) : -1;
    CHECK(sleeps == 0, "5 ms of yields with GetThreadPriority between them: no back-off (%ld sleeps)", sleeps);
    return NULL;
}
int main(void) {
    setenv("DM_YIELD_BACKOFF", "250", 0);   // off by default in the host
    pthread_t t; pthread_create(&t, NULL, guest, NULL); pthread_join(t, NULL);
    printf("t_sleep: %d checks, %d failed\n", n, fail); return fail != 0;
}
