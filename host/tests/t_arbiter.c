// svc 0x34 WaitForAddress / 0x35 SignalToAddress as Horizon's address arbiter (checked against Atmosphère's KAddressArbiter): type 3 waits while
// a 64-bit value is equal (8-byte aligned), the address is checked before the type, unknown types are refused; and the kernel's updates of the
// word (decrement if less than, increment if equal, modify by waiting count) are compare-and-swaps that a user-space adder racing them cannot
// lose an update to (LASRecomp's tools/test_condvar.c races the same way).
#include "../dm.h"
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
int svc_thread(int num, uint64_t *regs);
uint32_t svc_thread_main_init(void);
void (*dm_test_cv_after_release)(void);   // DM_TEST_HOOKS (t_condvar uses it)
static int n, fail;
#define EXPECT(name, want, got) do { unsigned long long w_ = (want), g_ = (got); n++; printf("%-78s expected %#-10llx → got %#-10llx %s\n", name, w_, g_, w_ == g_ ? "✓" : "✗"); fail += w_ != g_; } while (0)
enum { R_TIMEOUT = 0xEA01, R_BAD_STATE = 0xFA01, R_BAD_ENUM = 0xF001, R_BAD_ADDR = 0xCC01 };
static uint64_t wait_addr(void *a, int type, int64_t value, int64_t ns) { uint64_t r[8] = {(uint64_t)a, (uint64_t)type, (uint64_t)value, (uint64_t)ns}; svc_thread(0x34, r); return r[0]; }
static uint64_t signal_addr(void *a, int type, int32_t value, int32_t count) { uint64_t r[8] = {(uint64_t)a, (uint64_t)type, (uint64_t)(uint32_t)value, (uint64_t)(uint32_t)count}; svc_thread(0x35, r); return r[0]; }

static _Alignas(16) uint64_t g_w64[2];
static _Atomic int g_waiting, g_signalled;

enum { RACE = 200000 };
static _Alignas(8) _Atomic int32_t g_word;
static _Atomic int g_go;
static void *adder(void *a) {   // user space: plain atomic adds to the word the kernel updates
    (void)a; while (!atomic_load(&g_go)) {}
    for (int i = 0; i < RACE; i++) atomic_fetch_add(&g_word, 3);
    return NULL;
}

static void *guest(void *arg) {   // every WaitForAddress runs on this one guest thread; the main thread only signals
    (void)arg; svc_thread_main_init();
    // type 3: 64-bit equality. Equal with timeout 0: it would wait, so timed out (Atmosphère checks the value before the timeout)
    g_w64[0] = 5;
    EXPECT("type 3, value equal, timeout 0: timed out", R_TIMEOUT, wait_addr(&g_w64[0], 3, 5, 0));
    g_w64[0] = 0x0000000100000003ull;
    EXPECT("type 3, low words 3 < 5 but 64-bit values differ: invalid state", R_BAD_STATE, wait_addr(&g_w64[0], 3, 0x0000000200000005ll, 0));
    g_w64[0] = 0x0000000200000005ull;
    EXPECT("type 3, low words equal, high words differ: invalid state", R_BAD_STATE, wait_addr(&g_w64[0], 3, 0x0000000100000005ll, 0));
    EXPECT("type 3 at an address aligned to 4, not 8: invalid address", R_BAD_ADDR, wait_addr((char *)&g_w64[0] + 4, 3, 5, 0));
    EXPECT("type 2 at an address aligned to 4: accepted (value differs: invalid state)", R_BAD_STATE, wait_addr((char *)&g_w64[0] + 4, 2, 7, 0));
    EXPECT("type 0 at an odd address: invalid address", R_BAD_ADDR, wait_addr((char *)&g_w64[0] + 1, 0, 7, 0));
    EXPECT("type 4: invalid enum value", R_BAD_ENUM, wait_addr(&g_w64[0], 4, 5, 0));
    EXPECT("type -1: invalid enum value", R_BAD_ENUM, wait_addr(&g_w64[0], -1, 5, 0));
    // a type 3 waiter is woken by SignalToAddress on its address (from the main thread)
    g_w64[0] = 0x123456789abcdef0ull;
    atomic_store(&g_waiting, 1);
    EXPECT("type 3 waiter woken by a signal (type 0) on its address: success", 0, wait_addr(&g_w64[0], 3, (int64_t)0x123456789abcdef0ull, -1));
    EXPECT("... the signal came from the main thread", 1, atomic_load(&g_signalled));
    // SignalToAddress checks
    uint32_t *w32 = (uint32_t *)&g_w64[1]; *w32 = 9;
    EXPECT("signal type 3: invalid enum value", R_BAD_ENUM, signal_addr(w32, 3, 9, 1));
    EXPECT("... and the word is left alone (no increment)", 9, *w32);
    EXPECT("signal at an odd address: invalid address", R_BAD_ADDR, signal_addr((char *)w32 + 2, 0, 0, 1));
    EXPECT("signal type 1, value equal: success", 0, signal_addr(w32, 1, 9, 1));
    EXPECT("... the word is incremented", 10, *w32);
    // race: the kernel's increments (type 1, retried on invalid state) against user-space adds; no update may be lost
    atomic_store(&g_word, 0);
    pthread_t ad; pthread_create(&ad, NULL, adder, NULL);
    atomic_store(&g_go, 1);
    int incs = 0, retries = 0;
    while (incs < RACE) { int32_t v = atomic_load(&g_word); if (signal_addr((void *)&g_word, 1, v, 0) == 0) incs++; else retries++; }
    pthread_join(ad, NULL);
    EXPECT("race: increment-if-equal against user-space adds keeps every update", (uint64_t)RACE * 4, (uint64_t)atomic_load(&g_word));
    printf("    (%d kernel increments needed %d retries: the race happened)\n", incs, retries);
    // race: decrement if less than (type 1 wait, timeout 0) against user-space adds
    atomic_store(&g_word, 0); atomic_store(&g_go, 0);
    pthread_create(&ad, NULL, adder, NULL);
    atomic_store(&g_go, 1);
    int decs = 0;
    while (decs < RACE) if (wait_addr((void *)&g_word, 1, 0x7fffffff, 0) == R_TIMEOUT) decs++;
    pthread_join(ad, NULL);
    EXPECT("race: decrement-if-less-than against user-space adds keeps every update", (uint64_t)RACE * 2, (uint64_t)atomic_load(&g_word));
    return NULL;
}
int main(void) {
    pthread_t g; pthread_create(&g, NULL, guest, NULL);
    while (!atomic_load(&g_waiting)) usleep(1000);
    usleep(50000);
    atomic_store(&g_signalled, 1);
    EXPECT("signal (type 0) on the address of a type 3 waiter: success", 0, signal_addr(&g_w64[0], 0, 0, 1));
    pthread_join(g, NULL);
    printf("t_arbiter: %d checks, %d failed\n", n, fail); return fail != 0;
}
