// Render resolution. The game keeps its PC version's display settings (CameraManagerExtended) but offers no menu for them on Switch:
// SetResolutionLevel picks (width, height) from its configuration's table — 2560x1440 at level 0, which the console clamps to its 1920x1080
// swapchain — and calls Screen.SetResolution(int, int, bool), whose only caller on Switch it is. rules.py hands that function to host call 0x80:
// DM_RENDER_HEIGHT=<lines> makes the game render at most that many lines, the width keeping the aspect ratio (720 → 1280x720); the presenter scales
// the picture to the screen. The game sets its resolution once, when it loads its settings at startup: a change takes effect at the next launch.
// (Its PostProcessingActivity setting was tried the same way and left out: turning it off changed neither the picture nor the GPU load.)
#include <stdlib.h>
#include <string.h>
#include "dm.h"
#include "game.h"
#include "hle.h"

// Screen.SetResolution(int width, int height, bool fullscreen) at main+0x3327d00, taken over at its entry (svc ; ret). The original turns
// fullscreen into a FullScreenMode (1 FullScreenWindow, else 3 Windowed) and tail-calls the four-argument overload main+0x328c360 with
// RefreshRate {numerator 0, denominator 1} (x3 = 0x100000000); this does the same with the size scaled
static void (*g_set_resolution4)(int width, int height, int mode, uint64_t refresh_rate);
static int hc_set_resolution(uint64_t *r) {
    unsigned w = (uint32_t)r[0], h = (uint32_t)r[1];
    const char *e = getenv("DM_RENDER_HEIGHT"); int th = e ? atoi(e) : 0;
    if (th > 0 && h && (unsigned)th < h) {
        unsigned nw = (unsigned)(((uint64_t)w * (unsigned)th + h / 2) / h) & ~1u;
        LOG("graphics: the game sets its resolution %ux%u, rendering at %ux%u (DM_RENDER_HEIGHT=%d)", w, h, nw, (unsigned)th, th);
        w = nw; h = (unsigned)th;
    } else LOG("graphics: the game sets its resolution %ux%u", w, h);
    g_set_resolution4((int)w, (int)h, r[2] & 1 ? 1 : 3, 0x100000000ull);
    return 1;
}

void dm_game_boot(void) {
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) g_set_resolution4 = (void (*)(int, int, int, uint64_t))(void *)(g_mod[i].base + 0x328c360);
    if (!g_set_resolution4) die("graphics: module main not loaded");
    dm_host_call_register(0x80, hc_set_resolution);
}
