// Host lifecycle: graceful exit (SIGTERM; on iOS the app termination callback calls dm_host_shutdown).
// Waits for a save in progress to commit (dm_fs_save_wait), pauses audio and suspends graphics (waits for in-flight NVN calls and drains GPU work),
// then _exit(0); 1.5 s after the save wait it exits regardless.
// The default SIGTERM action would also exit quickly (code 143); this gives an orderly stop, exit code 0, and an entry for the iOS lifecycle.
#include "hle.h"
#include <TargetConditionals.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <signal.h>
#include <unistd.h>
void hlecount_flush(void);
double dm_fs_save_wait(double max_s, int *still);   // hle_fs.c
void dm_host_shutdown(const char *why) {
    static _Atomic int once; if (atomic_exchange(&once, 1)) return;
    uint64_t t0 = now_ns(); LOG("%s received: exiting", why);
    // A save in progress (written, not committed) is waited for first: up to 15 s on the Mac, 3 s on iOS, which ends a terminating app soon after
#if TARGET_OS_OSX
    double max_s = 15;
#else
    double max_s = 3;
#endif
    int still = 0; double w = dm_fs_save_wait(max_s, &still);
    if (w > 0.02) LOG("%s after waiting %.2f s for the save in progress to commit", still ? "[red] exiting without the uncommitted save" : "exiting", w);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        LOG("[red] exit did not finish within 1.5 s, exiting now"); _exit(0); });
    hlecount_flush();                               // DM_HLECOUNT: _exit skips atexit, so write it here
    dm_audio_suspend(1);
    dm_gfx_suspend(1);
    LOG("exit done (%.3f s)", (now_ns() - t0) / 1e9);
    _exit(0);
}
void dm_term_install(void) {
    signal(SIGTERM, SIG_IGN);                       // handled by a GCD signal source on an ordinary thread instead
    static dispatch_source_t src;
    src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    dispatch_source_set_event_handler(src, ^{ dm_host_shutdown("SIGTERM"); });
    dispatch_resume(src);
}
