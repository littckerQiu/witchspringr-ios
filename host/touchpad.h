// On-screen controls for a game steered with a controller (host/touchpad.c; game.json "touch": "pad"). Positions in points of the view the front
// end lays the controls out in. The front end calls tp_layout / tp_touch / tp_enable on its main thread and draws tp_draw(); hle_hid.c reads the
// controller they make at every read of the game (dm_touchpad_read).
#pragma once
#include <stdint.h>

enum { TP_DOWN, TP_MOVE, TP_UP };                     // tp_touch phases (UP also for a cancelled touch)
enum { TP_CIRCLE, TP_PILL, TP_DPAD, TP_EYE };         // shapes: TP_PILL is r wide and hh high (half sizes), the others r in radius
typedef struct { int shape; float x, y, r, hh; const char *label; int pressed; uint32_t dir; } tp_item;   // dir: the D-pad's direction held
typedef struct {
    int visible, collapsed, n; float u;               // collapsed: only the eye (items[0]); u: points per design point
    tp_item items[20];
    float home_x, home_y, stick_r; int stick; float bx, by, kx, ky;   // the floating stick at home, or its base and knob while held
    int look; float look_x, look_y;                    // a camera finger
} tp_draw_state;

void tp_layout(float w, float h, float safe_l, float safe_t, float safe_r, float safe_b);   // the view's size and safe area; again on any change
void tp_touch(long id, int phase, float x, float y);
void tp_enable(int on);            // every finger released; off (a game controller is connected): nothing drawn or read
void tp_set_hidden(int hidden);    // the eye's choice (the front end keeps it across launches)
int tp_hidden(void);
// The controller at time t (seconds, any monotonic clock): buttons and sticks in -1..1 (up positive); 0 when the controls are off
int tp_read(double t, uint64_t *buttons, float *lx, float *ly, float *rx, float *ry);
void tp_draw(tp_draw_state *d);
int tp_find(const char *label, float *x, float *y, float *r);   // a control's centre and size ("eye", "dpad", button labels); 0 if none

int dm_touchpad_read(uint64_t *buttons, int32_t *lx, int32_t *ly, int32_t *rx, int32_t *ry);   // hle_hid.c, the game's thread
void dm_touchpad_selftest_start(void);   // DM_TEST_TOUCHPAD (main.c)
