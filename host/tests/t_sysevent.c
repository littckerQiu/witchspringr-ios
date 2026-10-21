// SystemEvents of the service layer (hle_thread.c hle_bind_system_event / hle_signal_system_event, nxnative 8530042): a SystemEvent destroyed (both
// handles closed) and bound again at the same address gets a new kernel event although a decoy event took the freed handle numbers (the handle table
// hands out the lowest free slot): the signal reaches the new event, not the decoy; the same for 2,000 rounds. The binding used to outlive its handle:
// binding again did nothing and the signal went to the decoy. The SDK's CreateSystemEvent is a stand-in here that creates the kernel event (svc 0x45).
#include "../dm.h"
int svc_thread(int num, uint64_t *regs);
uint32_t svc_thread_main_init(void);
void hle_bind_system_event(void *ev, int autoclear);
void hle_signal_system_event(void *ev);
void (*dm_test_cv_after_release)(void);   // DM_TEST_HOOKS (t_condvar uses it)
static int n, fail;
#define CHECK(c, ...) do { n++; if (c) printf("  ✓ "); else { fail++; printf("  ✗ "); } printf(__VA_ARGS__); printf("\n"); } while (0)
typedef struct { uint32_t w, r; } fake_se;   // stands for the SDK's SystemEventType
static uint32_t fake_create(void *ev, int autoclear, int ipc) {
    (void)autoclear; (void)ipc; uint64_t r[32] = {0}; svc_thread(0x45, r); ((fake_se *)ev)->w = (uint32_t)r[1]; ((fake_se *)ev)->r = (uint32_t)r[2]; return (uint32_t)r[0];
}
static uint32_t fake_getw(const void *ev) { return ((const fake_se *)ev)->w; }
void *guest_sym(const char *name) {
    if (!strcmp(name, "_ZN2nn2os17CreateSystemEventEPNS0_15SystemEventTypeENS0_14EventClearModeEb")) return (void *)fake_create;
    if (!strcmp(name, "_ZN2nn2os30GetWritableHandleOfSystemEventEPKNS0_15SystemEventTypeE")) return (void *)fake_getw;
    return NULL;
}
static void closeh(uint32_t h) { uint64_t r[32] = {h}; svc_thread(0x16, r); }
static int take(uint32_t rh) { uint64_t r[32] = {rh}; svc_thread(0x17, r); return r[0] == 0; }   // ResetSignal: 1 when it was signaled (and clears it)
int main(void) {
    svc_thread_main_init();
    static fake_se ev;
    hle_bind_system_event(&ev, 0); uint32_t w1 = ev.w, r1 = ev.r;
    hle_signal_system_event(&ev);
    CHECK(w1 && take(ev.r), "a bound SystemEvent: the signal reaches its read end");
    closeh(ev.w); closeh(ev.r); memset(&ev, 0, sizeof ev);   // the guest destroys it
    uint64_t d[32] = {0}; svc_thread(0x45, d); uint32_t dw = (uint32_t)d[1], dr = (uint32_t)d[2];
    CHECK(dw == w1 && dr == r1, "a decoy event takes the freed handle numbers (%#x, %#x)", dw, dr);
    hle_bind_system_event(&ev, 0);   // the service binds the SystemEvent created again at the same address
    hle_signal_system_event(&ev);
    CHECK(ev.w && ev.w != dw, "bound again: a new kernel event (write handle %#x, the decoy's %#x)", ev.w, dw);
    CHECK(!take(dr), "the decoy is not signaled");
    CHECK(ev.r && take(ev.r), "the signal reaches the new event");
    closeh(ev.w); closeh(ev.r); closeh(dw); closeh(dr); memset(&ev, 0, sizeof ev);
    int bad = 0;
    for (int i = 0; i < 2000; i++) {
        hle_bind_system_event(&ev, 0); hle_signal_system_event(&ev);
        if (!take(ev.r)) bad++;
        closeh(ev.w); closeh(ev.r); memset(&ev, 0, sizeof ev);
        uint64_t q[32] = {0}; svc_thread(0x45, q);   // a decoy on the freed numbers, closed again after the next round
        hle_bind_system_event(&ev, 0); hle_signal_system_event(&ev);
        if (take((uint32_t)q[2]) || !take(ev.r)) bad++;
        closeh(ev.w); closeh(ev.r); closeh((uint32_t)q[1]); closeh((uint32_t)q[2]); memset(&ev, 0, sizeof ev);
    }
    CHECK(!bad, "2,000 rounds of bind / signal / destroy with a decoy: %d wrong", bad);
    printf("t_sysevent: %d checks, %d failed\n", n, fail); return fail != 0;
}
