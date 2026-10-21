// The no-progress watchdog (crash.c, DM_WATCH_STALL) and the background (plan item 51): each case runs in a child with a 2 s stall limit.
//   away:   in the background (guest clock frozen for reason 1) for 4 s without progress, then back with progress: not killed (exit 0)
//   stuck:  4 s without progress in the foreground: killed (128 + SIGALRM, a "[red] watchdog" line)
//   after:  4 s in the background, then 3 s without progress after the return: killed (counting starts again at the return)
// Before the fix a DM_TEST_BG run of Tears of the Kingdom was killed 15 s into its background. Negative control: -DDM_TEST_WATCH_NO_BG (the
// background not taken into account) kills "away".
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../dm.h"
void crash_install(void);
static _Atomic int g_bg;
int guest_clock_frozen_for(int reason) { return reason == 1 && atomic_load(&g_bg); }
static int fails, checks;
#define CHECK(c, ...) do { checks++; if (c) printf("  ✓ "); else { fails++; printf("  ✗ "); } printf(__VA_ARGS__); printf("\n"); } while (0)
static void child(int kind) {
    setenv("DM_WATCH_STALL", "2", 1); crash_install();
    crash_watch_pregame_done(); crash_watch_progress(1, "start");
    if (kind == 0) { atomic_store(&g_bg, 1); sleep(4); atomic_store(&g_bg, 0); crash_watch_progress(2, "back"); usleep(500000); _exit(0); }
    if (kind == 1) { sleep(4); _exit(0); }
    atomic_store(&g_bg, 1); sleep(4); atomic_store(&g_bg, 0); sleep(3); _exit(0);
}
static int run(int kind, char *out, size_t n) {
    int pf[2]; if (pipe(pf)) return -1;
    pid_t p = fork(); if (!p) { dup2(pf[1], 2); close(pf[0]); close(pf[1]); child(kind); }
    close(pf[1]); int st; waitpid(p, &st, 0);
    ssize_t k = 0, r; while (k < (ssize_t)n - 1 && (r = read(pf[0], out + k, n - 1 - k)) > 0) k += r; out[k] = 0; close(pf[0]);
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    static char out[65536]; int code;
    code = run(0, out, sizeof out);
    CHECK(code == 0 && !strstr(out, "[red] watchdog"), "away: 4 s in the background without progress, back with progress: not killed (exit %d)", code);
    code = run(1, out, sizeof out);
    CHECK(code == 128 + SIGALRM && strstr(out, "[red] watchdog: no progress"), "stuck: 4 s without progress in the foreground: killed (exit %d)", code);
    code = run(2, out, sizeof out);
    CHECK(code == 128 + SIGALRM && strstr(out, "[red] watchdog: no progress"), "after: no progress after the return: killed (exit %d)", code);
    printf("t_watchdog: %d checks, %d failed\n", checks, fails); return fails != 0;
}
