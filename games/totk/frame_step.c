// Real-time frame step. Tears of the Kingdom advances its world every frame by a step it derives from the present interval its frame-rate
// controller chose (ratio = 30 / fps: 1 at 30 fps, 0.5 at 60), which is right only while every frame takes exactly that interval. rules.py
// (HOSTREFS) makes the two producers of the step read it from main's host page instead, and this writes the measured frame time there at every
// present, so the game keeps its speed at 60, 90 or 120 fps (DM_PRESENT_HZ) and when a frame misses its interval.
// Method and limits from MacNativeGames' game_patches_v143.c (runtime_frame_step_update; ly05010419/MacNativeGames, MIT): the mean of the last five
// present intervals, each clamped to 1/120 .. 1/15 s; an interval above 0.25 s or below 1 ms (loading, a pause) restarts the mean and keeps the
// step. Intervals are on the guest clock, the one behind the game's own system tick.
// Host page: +0 ratio = seconds × 30, +4 ticks = seconds × 60, written with one 64-bit store so the game never reads the two from different frames.
// DM_FRAME_STEP_MS=<ms> pins the step (diagnostics: a pinned 16.667 at 90 fps makes the game run 1.5 times too fast).
// +16 / +20: the scene render size as floats (rules.py, plan item 52: main 0x585e48-0x585e60 store it to the renderer instead of the graphics
// parameter's): DM_RENDER_RES=<w>x<h> (64 up to 1920x1080, the output size: 2560x1440 and 3200x1800 crashed the game at main+0x1c2f20 in its first
// seconds; larger needs item 63's heap), else the parameter's own size for the operation mode, which a probe at main 0x585e4c read once at boot
// (docked 1600x900, handheld 1280x720), so the game looks as before unless asked.
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include "dm.h"
#include "game.h"
int dm_opmode(void);   // hle_oe.c

typedef struct { uint64_t last_ns; double dt[5]; unsigned n, next; } frame_mean;
// Feeds one present time; returns the step in seconds, or 0 when the step stays as it is
static double frame_mean_add(frame_mean *m, uint64_t now_ns) {
    if (!m->last_ns || now_ns <= m->last_ns) { m->last_ns = now_ns; return 0; }
    double dt = (now_ns - m->last_ns) * 1e-9; m->last_ns = now_ns;
    if (dt > 0.25 || dt < 0.001) { m->n = m->next = 0; return 0; }
    if (dt < 1.0 / 120) dt = 1.0 / 120;
    if (dt > 1.0 / 15) dt = 1.0 / 15;
    m->dt[m->next++ % 5] = dt; if (m->n < 5) m->n++;
    double sum = 0; for (unsigned i = 0; i < m->n; i++) sum += m->dt[i];
    return sum / m->n;
}
// The scene size for the page; returns 1 when it comes from env (DM_RENDER_RES), 0 for the game's own, -1 for a value it refused (the game's own)
static int scene_size(const char *env, int opmode, float out[2]) {
    out[0] = opmode ? 1600 : 1280; out[1] = opmode ? 900 : 720;
    if (!env || !*env || !strcmp(env, "0")) return 0;
    unsigned w, h; char extra;
    if (sscanf(env, "%ux%u%c", &w, &h, &extra) != 2 || w < 64 || h < 64 || w > 1920 || h > 1080) return -1;
    out[0] = (float)w; out[1] = (float)h; return 1;
}
static void frame_step_store(_Atomic uint64_t *page, double seconds) {
    float v[2] = {(float)(seconds * 30), (float)(seconds * 60)}; uint64_t bits; memcpy(&bits, v, sizeof bits);
    atomic_store_explicit(page, bits, memory_order_release);
}

#ifndef FRAME_STEP_TEST
static _Atomic uint64_t *g_page;
static frame_mean g_mean;
static double g_pin;
static int g_realtime;   // the option realtime is on: the step is the measured frame time
void dm_game_boot(void) {
    g_page = dm_host_page("main");
    if (!g_page) { LOG("[red] frame step: main has no host page (product built without rules.py HOSTREFS): the game's step stays at its chosen interval"); return; }
    const char *e = getenv("DM_FRAME_STEP_MS"); g_pin = e ? atof(e) / 1000 : 0;
    frame_step_store(g_page, g_pin > 0 ? g_pin : 1.0 / 30);   // the controller starts at interval 2
    if (dm_option_on("scene")) {
        float sz[2]; int from = scene_size(getenv("DM_RENDER_RES"), dm_opmode(), sz); memcpy((uint8_t *)g_page + 16, sz, sizeof sz);
        if (from < 0) LOG("[red] DM_RENDER_RES=%s: expected <width>x<height>, from 64x64 up to 1920x1080; the game's own size", getenv("DM_RENDER_RES"));
        LOG("[scene size] %.0fx%.0f (%s)", sz[0], sz[1], from > 0 ? "DM_RENDER_RES" : dm_opmode() ? "the game's own, docked" : "the game's own, handheld");
    } else if (getenv("DM_RENDER_RES")) LOG("[red] DM_RENDER_RES needs the option scene (DM_OPTIONS)");
    if (!(g_realtime = dm_option_on("realtime"))) { LOG("[frame step] the game's own (option realtime not on: DM_OPTIONS or the product's options.default)"); return; }
    if (g_pin > 0) LOG("[frame step] pinned at %.3f ms (DM_FRAME_STEP_MS, diagnostics)", g_pin * 1000);
    else LOG("[frame step] real time: the mean of the last five present intervals (1/120 .. 1/15 s each)");
}
int dm_game_realtime_step(void) { return g_realtime && g_pin <= 0; }   // (a pinned step needs the fixed pacing)
void dm_game_present(void) {
    if (!g_realtime || g_pin > 0) return;
    double s = frame_mean_add(&g_mean, guest_ns());
    if (s > 0) frame_step_store(g_page, s);
}
#endif
