// Host-initiated guest threads: host work that has to call into the game's SDK (its allocator, nn::os locks, the in-process audio renderer of
// hle_audren.c) needs a complete SDK thread context. The thread is created by the SDK itself (nn::os::CreateThread / StartThread) with a host function
// as the entry, so ThreadType, thread handle and TLS are in place. Must be called on a guest thread (SDK thread creation goes through the svc gate).
// From nxnative's hle_guestthread.c (seedds, MIT), without its self-test.
#include "hle.h"

typedef int (*create_fn)(void *tt, void (*fn)(void *), void *arg, void *stack, size_t size, int prio);
typedef void (*tt_fn)(void *tt);
static void *need(const char *n) { void *p = guest_sym(n); if (!p) die("host guest thread: no SDK symbol %s", n); return p; }

void *dm_guest_thread_spawn(void (*fn)(void *), void *arg, int prio, size_t stack_size) {
    stack_size = (stack_size + 0xfff) & ~(size_t)0xfff;
    void *tt = calloc(1, 0x200);                                 // nn::os::ThreadType (0x1c0 bytes, with headroom)
    void *stack = aligned_alloc(0x1000, stack_size);             // the SDK wants a 4 KiB aligned stack whose size is a multiple of 4 KiB
    if (!tt || !stack) die("host guest thread: out of memory");
    void dm_thread_next_host_work(void); dm_thread_next_host_work();   // the thread runs host code: no virtual core (hle_thread.c)
    int rc = ((create_fn)need("_ZN2nn2os12CreateThreadEPNS0_10ThreadTypeEPFvPvES3_S3_mi"))(tt, (void (*)(void *))dm_hwrap((void *)fn), arg, stack, stack_size, prio);   // fn runs on the host stack
    if (rc) die("host guest thread: CreateThread failed %#x", rc);
    ((tt_fn)need("_ZN2nn2os11StartThreadEPNS0_10ThreadTypeE"))(tt);
    return tt;
}
void dm_guest_thread_join(void *tt) { ((tt_fn)need("_ZN2nn2os10WaitThreadEPNS0_10ThreadTypeE"))(tt); ((tt_fn)need("_ZN2nn2os13DestroyThreadEPNS0_10ThreadTypeE"))(tt); }
