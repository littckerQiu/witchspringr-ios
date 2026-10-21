// Touchscreen: the front end pushes the whole set of touch points (dm_touch_set, front.h); the game reads them through nn::hid::GetTouchScreenState(s)
// (hle_hid.c → touch_fill). Normalized coordinates [0,1) (origin top left of the game picture) are scaled to the game's touch space (touch_space).
// Short-press latch: a game may look only at the newest state, so a finger pressed and lifted between two reads would be lost. Every finger is reported
// once as Start, and once more as End after it is lifted, before its slot is freed.
// TouchState (0x28 bytes, = libnx HidTouchState): +0 delta_time (ns, i64), +8 attributes (bit0 Start / bit1 End), +0xc finger_id, +0x10 x, +0x14 y,
// +0x18 diameter x, +0x1c diameter y, +0x20 rotation angle, +0x24 reserved. TouchScreenState<16>: +0 sample number, +8 touch count, 16 TouchState from +0x10.
// DM_TOUCH_LOG=1 logs each read that has touch points (first 500); DM_TOUCH_SPACE=WxH forces the touch space.
#include "dm.h"
#include "front.h"
#include "game.h"
#include <pthread.h>
#include <stdatomic.h>
enum { F_EMPTY, F_DOWN, F_LIFTED };
static struct { int st, reported, again; float x, y, ax, ay; } g_f[16];   // again / ax / ay: the same id pressed again before its End went out
static pthread_mutex_t g_tl = PTHREAD_MUTEX_INITIALIZER;
static int64_t g_tsamp; static uint64_t g_tlast_ns;

void dm_touch_set(const dm_touch *t, int n) {
    pthread_mutex_lock(&g_tl);
    int seen[16] = {0};
    for (int i = 0; i < n; i++) {
        uint32_t id = t[i].id; if (id >= 16) continue;
        seen[id] = 1;
        if (g_f[id].st == F_LIFTED && g_f[id].reported) { g_f[id].again = 1; g_f[id].ax = t[i].x; g_f[id].ay = t[i].y; continue; }
        if (g_f[id].st == F_EMPTY) { g_f[id].st = F_DOWN; g_f[id].reported = 0; }
        else if (g_f[id].st == F_LIFTED) g_f[id].st = F_DOWN;   // pressed again before the lift was reported: held down all along
        g_f[id].x = t[i].x; g_f[id].y = t[i].y;
    }
    for (int id = 0; id < 16; id++) {
        if (!seen[id] && g_f[id].st == F_DOWN) g_f[id].st = F_LIFTED;
        if (!seen[id] && g_f[id].again) g_f[id].again = 0;       // pressed again and lifted again before End went out: drop the re-press
    }
    pthread_mutex_unlock(&g_tl);
}

// Touch space (width × height): the game picture size once the game sets its crop (Unity reads touches as screen pixels, x as is, y = height − y),
// before that the profile's screen size; DM_TOUCH_SPACE overrides both
static _Atomic int g_sw, g_sh;
void dm_touch_screen(int w, int h) { if (w > 0 && h > 0) { g_sw = w; g_sh = h; } }
static void touch_space(int *w, int *h) {
    static int fw = -1, fh;
    if (fw < 0) { const char *e = getenv("DM_TOUCH_SPACE"); if (!e || sscanf(e, "%dx%d", &fw, &fh) != 2 || fw <= 0 || fh <= 0) fw = 0; }
    if (fw) { *w = fw; *h = fh; return; }
    if (g_sw) { *w = g_sw; *h = g_sh; return; }
    *w = dm_game.screen_w > 0 ? dm_game.screen_w : 1280; *h = dm_game.screen_h > 0 ? dm_game.screen_h : 720;
}
static int32_t clampi(float v, int hi) { int32_t r = (int32_t)(v * (float)(hi + 1)); return r < 0 ? 0 : r > hi ? hi : r; }
// Fill one TouchScreenState<16> (0x290 bytes); now_ns gives delta_time. Returns the number of touch points written
int touch_fill(void *out, uint64_t now_ns) {
    uint8_t *o = out; memset(o, 0, 0x290);
    pthread_mutex_lock(&g_tl);
    int64_t samp = ++g_tsamp; int64_t dt = g_tlast_ns ? (int64_t)(now_ns - g_tlast_ns) : 0; g_tlast_ns = now_ns;
    int tw, th; touch_space(&tw, &th);
    int k = 0;
    for (int id = 0; id < 16; id++) {
        if (g_f[id].st == F_EMPTY) continue;
        uint32_t attr = 0;
        if (!g_f[id].reported) { attr |= 1; g_f[id].reported = 1; }   // Start (first report)
        else if (g_f[id].st == F_LIFTED) attr |= 2;                  // End (Start was reported, now lifted)
        uint8_t *s = o + 0x10 + 0x28 * k++;
        int32_t x = clampi(g_f[id].x, tw - 1), y = clampi(g_f[id].y, th - 1), d = 30, zero = 0, fid = id;
        memcpy(s + 0x00, &dt, 8); memcpy(s + 0x08, &attr, 4); memcpy(s + 0x0c, &fid, 4);
        memcpy(s + 0x10, &x, 4); memcpy(s + 0x14, &y, 4); memcpy(s + 0x18, &d, 4); memcpy(s + 0x1c, &d, 4); memcpy(s + 0x20, &zero, 4);
        if (attr & 2) {   // End reported: free the slot, or start the re-press that came in meanwhile
            if (g_f[id].again) { g_f[id].st = F_DOWN; g_f[id].reported = 0; g_f[id].again = 0; g_f[id].x = g_f[id].ax; g_f[id].y = g_f[id].ay; }
            else g_f[id].st = F_EMPTY;
        }
    }
    pthread_mutex_unlock(&g_tl);
    int32_t cnt = k; memcpy(o + 0, &samp, 8); memcpy(o + 8, &cnt, 4);
    static int lg = -1, nl; if (lg < 0) lg = getenv("DM_TOUCH_LOG") != NULL;
    if (lg && k && nl < 500) {
        char b[256]; int m = snprintf(b, sizeof b, "touch read: sample %lld, %d points", (long long)samp, k);
        for (int i = 0; i < k && m < (int)sizeof b - 40; i++) { int32_t v[4]; memcpy(v, o + 0x10 + 0x28 * i + 0x08, 16);
            m += snprintf(b + m, sizeof b - m, " | #%d (%d,%d) attr %d", v[1], v[2], v[3], v[0]); }
        LOG("%s (space %dx%d)", b, tw, th); if (++nl == 500) LOG("DM_TOUCH_LOG: 500 lines, stopping");
    }
    return k;
}
