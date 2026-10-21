// Present pacer (pure function, shared by Mac / iOS; unit test tests/t_pace.c).
// Semantics as vsync: present slot = previous present slot + period. Early → wait until the present slot; late by less than one period → present immediately and keep the original phase;
// behind by one period or more (stutter) → restart the cadence from the current time, no burst of presents to catch up. Period 0 = no wait (the present slot follows the current time).
#pragma once
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint64_t target; } nvn_pacer;

// now: monotonic clock (ns); period: this frame's period (ns, 0 = no wait). Returns the ns to wait (0 = present immediately) and updates the internal target time.
static inline uint64_t nvn_pace(nvn_pacer *p, uint64_t now, uint64_t period) {
    if (!period || !p->target) { p->target = now; return 0; }
    uint64_t next = p->target + period;
    if (now <= next) { p->target = next; return next - now; }
    p->target = now - next < period ? next : now;
    return 0;
}

// Uncapped pacing (plan item 53, after MacNativeGames' TOTK_UNCAPPED, ly05010419/MacNativeGames, MIT): for a game whose step follows the measured
// frame time (the host's dm_game_realtime_step), the game does not wait for the display. Our own clock paces it at up to `cap` Hz (its present
// interval × 1 / cap a frame) and the display link shows the newest finished frame at each refresh, so a scene slower than 60 fps shows at its own
// rate instead of the next step down (30). Off with DM_UNCAPPED=0, with DM_PRESENT_HZ (a fixed rate asked for) and on a display of 120 Hz or more
// (nothing to gain there). The cap: DM_UNCAPPED_HZ=30..120 or "display" (the display's rate, 60 without one); 120 at most, as the frame step counts a
// frame as at least 1/120 s. Returns the clock rate in Hz, 0 for the usual pacing.
static inline int nvn_uncapped_hz(int realtime_step, const char *present_hz, const char *uncapped, const char *cap, int display_hz) {
#ifdef DM_TEST_UNCAPPED_ANY_STEP   // negative control of t_pace only: a game stepping per frame paced uncapped too (it would run fast)
    (void)realtime_step;
    if (present_hz || (uncapped && !strcmp(uncapped, "0")) || display_hz >= 120) return 0;
#else
    if (!realtime_step || present_hz || (uncapped && !strcmp(uncapped, "0")) || display_hz >= 120) return 0;
#endif
    int v = !cap || !*cap ? 120 : !strcmp(cap, "display") ? (display_hz > 0 ? display_hz : 60) : atoi(cap);
    return v < 30 ? 30 : v > 120 ? 120 : v;
}
