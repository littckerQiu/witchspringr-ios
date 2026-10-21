// nn::vi (display layer): on a real device, the vi service is used to open the display, create a layer and get the native window handle; the handle is passed to NVN's window builder.
// Host: returns host static objects; when hooking up Metal, the native window corresponds to the front end's CAMetalLayer (front_metal_layer()).
#include "../host/hle.h"

static struct { uint32_t magic; } g_display = {0x50534944}, g_layer = {0x5259414c};
static struct { uint32_t magic; void *layer; } g_native = {0x4e49574e, 0};

HLE_FORCE("_ZN2nn2vi10InitializeEv", "display service init; the host has no vi service", void, h_vi_Init, void) {}
HLE_FORCE("_ZN2nn2vi18OpenDefaultDisplayEPPNS0_7DisplayE", "open the default display; the host returns a static object", Result, h_vi_OpenDisp, void **out) {
    *out = &g_display; return RES_OK;
}
HLE_FORCE("_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayE", "create a layer; the host returns a static object", Result, h_vi_CreateLayer, void **out, void *disp) {
    (void)disp; *out = &g_layer; return RES_OK;
}
HLE_FORCE("_ZN2nn2vi15GetNativeWindowEPPvPNS0_5LayerE", "native window handle, passed to the NVN window builder; the host returns a static object", Result, h_vi_GetNative, void **out, void *layer) {
    (void)layer; *out = &g_native; return RES_OK;
}

// Display vsync event (games that pace frames on it, e.g. Unity): bound on the caller's guest thread, then signaled by a host thread at the
// display rate (60 Hz). Auto-clear, like the real vsync event: each wait consumes one tick
#include <pthread.h>
#include <time.h>
static void *g_vsync_ev; static pthread_once_t g_vsync_once = PTHREAD_ONCE_INIT;
static void *vsync_thread(void *a) {
    (void)a; uint64_t next = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    for (;;) {
        next += 16666667;   // absolute schedule: sleep overshoot does not accumulate
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (next > now) { struct timespec r = {(time_t)((next - now) / 1000000000ull), (long)((next - now) % 1000000000ull)}; nanosleep(&r, NULL); }
        else if (now - next > 100000000ull) next = now;   // fell far behind (process suspended): resync instead of bursting
        hle_signal_system_event(g_vsync_ev);
    }
    return NULL;
}
static void vsync_start(void) { pthread_t th; if (pthread_create(&th, NULL, vsync_thread, NULL)) die("cannot start the vsync thread"); pthread_detach(th); }
HLE_FORCE_OPT("_ZN2nn2vi20GetDisplayVsyncEventEPNS_2os15SystemEventTypeEPNS0_7DisplayE", "display vsync event: bound to a kernel event, signaled at 60 Hz by a host thread", Result, h_vi_VsyncEv, void *ev, void *disp) {
    (void)disp;
    if (g_vsync_ev && g_vsync_ev != ev) LOG("[red] vi::GetDisplayVsyncEvent: second event %p (only the first, %p, is driven)", ev, g_vsync_ev);
    if (!g_vsync_ev) { hle_bind_system_event(ev, 1); g_vsync_ev = ev; pthread_once(&g_vsync_once, vsync_start); }
    return RES_OK;
}
